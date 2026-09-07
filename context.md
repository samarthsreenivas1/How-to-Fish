# Context for agents picking up this project

Read this first; keep it SHORT. This is the compressed handoff (2026-09-06,
user order: ~200 lines). The full 3,464-line encyclopedia is preserved at
commit **7d903cc** — `git show 7d903cc:context.md` — and per-system history
lives in `git log`. When you add to this file, add a LINE, not an essay.

## What this is

A Roblox fishing + combat game. Cast at water → timing minigame → the catch
is thrown at you, hostile → fight it for coins/XP/materials → craft rods,
weapons, armor, boats. Seven-island saga (cove → swamp → ice → volcano →
gloom → wreck → Maelstrom), a bait-summoned boss per island whose heart
gates travel onward, Kraken finale. Plus NPCs/quests/bestiary/economy, nine
decorative islets, drivable boats, per-island water/weather. **All content
is data rows** (`src/Shared/Data/`), not code paths.

State: the full saga is in the tree and playable end to end; the project is
in post-ship iteration. Almost everything is **unreviewed in Studio** —
expect a tuning round on anything you touch. Studio re-imports owed at any
moment: **`docs/import-checklist.md` is the ledger, trust it over dates.**

## Working style

- **Thin slices, one per prompt**, each ending playable in Studio. Don't
  build ahead; stub and comment. The user reviews visually; refinement
  prompts are part of the slice, not scope creep.
- **Pre-commit gate, no exceptions:** `stylua src` && `selene src` (0/0/0)
  && `rojo build -o /tmp/check.rbxlx` && `python3 tools/check_content.py`
  && `python3 tools/check_compile.py`. Rojo doesn't parse Luau and selene
  doesn't allocate registers; only gate 5 compiles (200-local chunk cliff).
- **The uploaded icon set is CANON for item art.** Model vs icon disagree →
  the model is wrong.
- `git add <explicit paths>`, never `-A`. Commit messages explain WHY.

### Concurrency (several Claude sessions edit this repo at once)

- `ListAgents`, claim files by message before editing shared ones.
- **The git index is shared**: stage + commit in ONE shell invocation.
- A file carrying another lane's uncommitted work is committed by **splice**:
  rebuild your delta on `git show HEAD:<file>`, `git hash-object -w` +
  `git update-index --cacheinfo`, commit — then make the TREE match what you
  committed (once). Verify afterwards that the remaining tree diff is purely
  theirs.
- **Text-edit rules** (three lanes were burned in one night): anchor on
  strings unique to your section, `assert count == 1` AND `assert old` (an
  empty needle makes `str.replace` prepend forever, silently), INSERT at
  anchors rather than replace-in-place (a replace whose target is missing
  silently skips), treat registry dicts (`BOSSES`/`PLACERS`/`STAGERS`/
  `CAMERAS`/`SCENE`) as extraction end-markers, and assert no peer symbol
  appears in anything you cut. Re-read a hot file immediately before writing.
- **Did my edit move someone else's mesh?** Build HEAD vs HEAD+your-block
  (never tree-vs-tree — live lanes cause false positives) and diff
  `python3 tools/mesh_digest.py` output. PNGs and GLBs are NOT
  byte-reproducible here, and bbox diffs are blind to interior edits.
- **A control that cannot run looks exactly like a control that passed**:
  every verification needs a positive control on the SPECIFIC change, and
  the control must assert its own anchor still exists and its build produced
  output. A proof that excludes the region you changed is not evidence about
  the change. Enumerate, or say "I checked three" — don't write a sampled
  rule down as a general one.

## Architecture (established — don't deviate without reason)

- **Service/controller pattern, no framework.** `Server/Services/*` and
  `Client/Controllers/*`, plain tables with `init()`/`start()`, explicit
  load-bearing `ORDER` in `init.server.luau`/`init.client.luau`. Boot is
  **fail-fast**: one broken module (or an ORDER name with no file) kills
  every controller — symptom is third-person camera / empty world; read
  Output for `[Boot]`.
- Constants in `Shared/Config/` (`World`, `Ocean`, `Tuning` = every balance
  number); content rows in `Shared/Data/`; remotes declared ONCE in
  `Shared/Net/Remotes.luau`; replicated **attributes** for scalar state;
  client feedback controllers key off attributes/events, never off sources.
- **No Humanoid on creatures; one Heartbeat for all** (`CreatureService`).
  Client predicts (swings, reel), server owns truth (damage, grants).
- Animations are **Blender-authored clips exported as Luau data**, not
  Roblox Animation assets.
- **Colossus bosses** (Brinejaw/Kraken/Noctyss/Pyrelisk/Gnashroot/…):
  `Shared/Modules/ChainPose.luau` poses part-chains along curves — PURE
  math, used by server (hitboxes) and client (drawing) off the same inputs.
  Per boss: a `<Boss>Path` module (curves/poses, authored-space constants
  copied from the generator's HANDOFF prints) + a `<Boss>BodyController`
  (clones `<Boss>Pack` pieces, seats them at measured authored offsets via
  the Wrack `packAnchor` pattern). Server side: `pose = "<boss>"` on the
  Bosses row routes to the posed branch (pins `creature.pos` to the anchor,
  hides the proxy), a `RIG_POSE` row makes `publishPose` emit the shared
  attribute vocabulary (`Attack/AttackBlend/Strike/AimAngle/AimSide` +
  `Rise/FaceAngle/Exposed`). **Aim is latched once at windup and held** —
  re-picking nearest-player per frame teleports a 40-stud limb. **Every
  number a hitbox uses must be a value the renderer also consumes**, and
  name the fraction, don't repeat it.

## Design decisions (binding — don't reopen without the user)

- Fishing/collection is the primary axis; combat makes a catch feel earned.
- **Every catch is hostile and is fought** — no passive tier, no auto-collect.
- Ranged weapons are live (user reversed the old "no guns" rule 2026-08-24).
- **First person**; hands are block Roblox limbs; no on-screen prompts
  beyond the bottom-left menu buttons; `I`/`B` inventory, `C` craft, `T`
  travel, `R` boat, `1`/`2` equip.
- A finished cast never fails; an abandoned one pays nothing (no AFK farming).
- Reel grade sets combat multipliers (`Tuning.Grade`).
- No `splat.wav`; creatures on water are silent.

## Asset pipeline (full walkthroughs: `assets/README.md`)

Everything visual is generated by Blender-python, run headless:
`blender --background --python-exit-code 1 --python assets/<gen>.py -- <out> [args]`
(macOS: `blender` is on PATH). Generators: `island_gen.py` (all islands +
islets, one pack), `fish_gen.py`, `creatures_gen.py`, `rod_gen.py`,
`weapon_gen.py`, `armor_gen.py`, `boat_gen.py`, `arena_gen.py` (boss lair
arenas), `boss_gen.py` (colossus boss packs), `water_gen.py`, and the
`*_anim.py` clip exporters (write straight to `Shared/Data/`, no import).

- Always `.glb`, never OBJ. Import in Studio under `ReplicatedStorage/Assets`
  keeping EXACT names; **do not scale on import** (rigs apply the row's
  scale themselves); right-click the Assets FOLDER → Save to File →
  `assets/Assets.rbxm`; restart `rojo serve`; commit the rbxm.
- Every consumer falls back to a stand-in with a `warn()` naming the import
  step, so the game always boots. Generators print HANDOFF lines — the
  numbers Luau modules copy; keep them in sync.
- `PreciseConvexDecomposition` on anything walkable (a Default hull CAPS
  carved bowls/holes — you walk on air). Parts named `Deco*` (arenas) are
  stripped of collision+query at runtime and need no import care.
- **Studio's importer drops all colour** — `Shared/Config/MeshColors.luau`
  repaints arena/boss packs; it is GENERATED (`tools/gen_mesh_colors.py`)
  after any builder palette change. Assert fight-critical visuals (a Neon
  core) in the controller's clone path, not in an import instruction; the
  `Glow`-in-name → Neon rule is BossArenaService's, ARENA meshes only.

## Gotchas (each of these cost real time — they'll bite again)

- **2048-stud BasePart size cap is real and silent** (the sea is a 32×32
  grid of 2040-stud tiles for this reason). MeshPart imports too.
- **The ocean is a solid collidable slab whose top face is WATER_Y.**
  Players stand on it; arena/island geometry carved BELOW the waterline does
  not exist at runtime (`verifyWaterline` warns at boot). Only boats get a
  pass-through group.
- **Never write a `.luau` from PowerShell** (UTF-8 BOM kills the whole boot;
  stylua/selene/rojo all pass it). Use Write/Edit tools.
- **Never write `CollisionFidelity` from a script** (Plugin-capability;
  throws and fail-fast kills every service after it). Set it in Studio.
- **Raycasts test COLLISION geometry, not the render mesh** — a convex hull
  caps craters/holes and every probe sees the cap.
- **An imported MeshPart's CFrame axes tell you nothing** (rotation baked
  into geometry); a part's Position is its bbox centre, not the feature's.
  Measure features (down-ray grids / PCA), don't assume.
- **Never leave an offset on camera.CFrame across frames** (it compounds);
  apply at `Camera+1`, undo at `Camera-1`.
- `rojo serve` reads the project file and rbxm once — restart after either
  changes. Can't connect the plugin during Play. Studio's Play camera eats
  `I`/`O` — give hotkeys a second key.
- **Bulk find/replace matches literals, not the rows you meant** — count
  occurrences first; shared colour literals recolour strangers.
- When a fix "doesn't work" three times, check the game is running your
  code (`rojo build` a place file to be sure).
- Boss engine sharp edges: `pose` currently implies rig+rooting+hide
  together; `openStagger` is only exitable for `entrenched` bosses (use a
  move's `expose` field otherwise); `ATTR_EXPOSED` never auto-clears for a
  plain boss (cue fires once); a handler that damages mid-strike belongs in
  `HANDLER_IMPACT` or its tell lies; an attack kind the client doesn't know
  falls back to a 3-stud flash — use a real `tell` or `tell = false` with
  per-strike marks; `damagePlayersInRadius` is body-centred.
- Mesh ids in `Assets.rbxm` load only for the user's account.

## Verification / where things live

```bash
stylua src && selene src && rojo build -o /tmp/check.rbxlx && python3 tools/check_content.py
python3 tools/mesh_digest.py <glb>   # per-object vertex hashes (see Concurrency)
```

`check_content.py` validates cross-file ids (recipes/rosters/orders) but NOT
phase→attack references or pose wiring — check those by hand. Layout:
`src/Shared/{Config,Data,Net,Modules}`, `src/Server/Services`,
`src/Client/{Controllers,Modules,UI}`, `assets/` (generators + glbs +
`Assets.rbxm`), `tools/`, `docs/` (`import-checklist.md`, `revamp-plan.md`).
Grep is the map; names are long and literal.

## Known gaps / next steps (don't start unprompted)

- **Gnashroot rooting wiring** (`CreatureService`: `pose` row + `RIG_POSE`
  entry + `colossusState` branch + pin/PivotTo in `placeColossus` +
  `gnashrootDrive`) — the verified 7-step plan is in git history (commit
  879ee96's message and the adversarial-review commits around it).
- Studio imports per `docs/import-checklist.md`; then review everything.
- Game-wide boss issues found by review, unfixed: `gatherParty` conscripts
  bystanders (no consent/level check); one hit grants heart + travel gate;
  killer-takes-all loot (payout evaporates if killer left).
- Touch can't cast/swap; other players see static rods (no swing replication).
