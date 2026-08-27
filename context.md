# Context for agents picking up this project

Read this first. It's a handoff doc, not user-facing — it exists so another
agent (or a future you, in a fresh context window) can get oriented in one
pass instead of re-deriving decisions from scratch. **Last full rewrite:
2026-08-22 (end of day).** Everything below is the state at that point; the
dated notes inside sections are there so you can tell old decisions from new.

## What this is

A Roblox fishing + melee game. You cast a rod at the water you're looking
at, play a timing minigame on a sweeping bar, the fish you land is thrown
out of the water at you, and you punch it to death for coins, XP and
crafting materials. Full pitch, design rationale, and the original
nine-slice plan live at:

**`C:\Users\sreen\.claude\plans\okay-i-want-you-melodic-hartmanis.md`**

(A second plan file covers crafting materials:
`C:\Users\sreen\.claude\plans\okay-add-materials-that-lovely-emerson.md`.)

The plan's slice order was island → rod → fishing → everything the catch
leads to. Slices 1–5 are built and most of 6–8 is in place in reduced form
(see "Where things stand"); the plan has been amended in place for the
design pivots listed under "Design decisions". Persistence (Slice 9) landed
2026-08-25 as `DataService`; the 7-island progression revamp
(`docs/revamp-plan.md` — the master design) was then **completed in full
overnight 2026-08-25→26 by five concurrent sessions** — all seven islands,
all seven bosses and hearts, the ranged engine, the boat, spawner/raids/
events, and the Kraken finale are in the tree. The user's import pass then
LANDED (all six packs; the game boots and plays end to end), three review
rounds closed every lane, and the project moved into **post-ship
iteration** (2026-08-26→27): two island visual-overhaul rounds, a bipedal
creature redesign, the guns rebuilt as guns, the melee arsenal rebuilt
with per-family swing classes, a per-gun reload-animation system, real
arrow projectiles, the voyage-arc map, and the **boss redesign** (every
post-cove boss got a unique moveset + gimmick + bespoke model — see "The
boss redesign") — see "The post-ship days". Standing re-imports owed at
any moment are tracked in `docs/import-checklist.md`; as of this rewrite:
`weapon.glb` (the 15 new melee models), `rod.glb` (the 25 bespoke
rods, be82f72), `island_pack.glb`, and `creatures.glb` (the 7 rebuilt
boss models, ba93efb).

## Working style — read this before starting any slice

The user reset a first attempt that built ~4,000 lines in one pass with no
room to steer. They explicitly want **thin slices, one per prompt**, each
ending at something playable in Studio. Concretely:

- Don't build ahead of the current ask. If a future slice needs a system,
  stub it minimally or leave a comment — don't build the whole thing early.
- Every slice ends **formatted, linted, and building** (commands at the end)
  before you consider it done.
- The user reviews visually in Studio after most slices — expect follow-up
  refinement prompts (sizes, colours, feel) even after a slice is "done".
  Treat those refinements as part of the slice, not scope creep. Several
  systems below are marked **not yet reviewed in Studio** — assume a tuning
  round is coming for each.
- When a request is genuinely ambiguous in a way that changes what gets
  built, ask. Don't guess silently on anything expensive to undo. But when
  the user repeats an ask after a fix didn't land, stop theorising and get a
  screenshot — two of the longest loops today (fist orientation, fish
  orientation) were resolved only once a picture made the cause obvious.
- **Several Claude sessions have been working on this project at once** (see
  the concurrency note under Gotchas). Before editing a shared file, check
  whether another session is live and claim the file.
- **Pre-commit gate (no exceptions):** `stylua src` + `selene src` (0/0/0) +
  `rojo build` + `python3 tools/check_content.py` — all four green before
  every commit. Full commands under "Tooling / verification".

## Where things stand (2026-08-22)

The loop is playable end to end: spawn on the beach → walk to the dock →
right-click at water to cast (rod swing, bobber arcs out) → reel bar → a
real-species fish is thrown over your head onto the sand (plus a couple of
basic materials) → press `2` for your weapon (fists, or a crafted club /
blade) → hit it (hit flash, numbers, impact VFX/SFX, knockback) → it dies →
"+coins +XP", rare material drops, a level-up banner → `C` to craft a
better rod or weapon once the level/mats/coins are there. A pufferfish
fights back and can hurt you; you have a health bar. Nothing persists
between sessions.

| System | State | Notes |
|---|---|---|
| Island, dock, foam rim, spawn | done, reviewed | Blender mesh pipeline; `Assets.rbxm` in repo |
| Stylised ocean | done, 3 passes | flat part + one scrolling caustics texture |
| First person + viewmodels | done, reviewed | block Roblox arms, Blender-authored cast & punch clips |
| Inventory + rod | done, reviewed | `I`/`B` modal; icons deliberately absent; one rod only |
| Equip rod / weapon | done | `1`/`2`; server-owned attributes (kind + which rod / which weapon) |
| Cast + reel minigame | done, reviewed | aim-at-water gating, thin bar, click anywhere |
| Creatures: 9 species (8 fish + pufferfish) | built, **species unreviewed** | one `FishPack` mesh; puffer is a real pack species now, with a parts fallback |
| Throw-at-player + flop | done, reviewed | scoped physics exception |
| Melee combat + feedback + VFX/SFX | done, partly reviewed | proximity targeting; numbers come off the equipped weapon row |
| Pufferfish rusher + player health + HUD | built, **unreviewed** | first hostile archetype |
| Hostile non-fish creatures + drops | built, **unreviewed** | crab (rusher) + 2 upright zombie `shambler`s; per-creature drops, rare item drop; procedural models |
| **Enemies slice 1: 8 new hostiles** | built, **unreviewed** | charger / spitter / bloater / drifter / burrower / mimic / thief / pulser archetypes, rows + procedural stand-ins, `CreatureEvent` client moments |
| **Enemies slice 2: CreaturePack art for the 8** | built, **unreviewed / re-import pending** | `creatures_gen.py` now builds 11 species; `creatures.glb` must be re-imported as `CreaturePack` + `Assets.rbxm` re-exported |
| **Volcano: fishable lava, rim bounds + walls** (2026-08-23) | **SUPERSEDED 2026-08-24** | rim-top design replaced by the tall-volcano redesign below; the rim sampler/walls machinery survives in WorldService but is dormant (no `Islands.volcano.rim` block any more) |
| **Volcano redesign: ~940-stud jagged stratovolcano, bottom dock over a lava delta** (2026-08-24) | built, **unreviewed / re-import pending** | see "Volcano" section; new `island_volcano.glb` + `island_pack.glb` generated; playable area = ash apron at sea level, ocean-bounded like the starter; `castRangeMult` 1.5; spawn moved to the apron by the dock |
| **Island boss: Brinejaw** (2026-08-22; bait-summoned 08-23) | built, **unreviewed / re-import pending** | `Bosses.luau` + `BossService` + "boss" archetype (8 attacks, 3 phases, enrage) + `BossHudController`; gates travel to the next island; Blender `Leviathan` species in `creatures.glb` (stand-in until re-import) |
| Coins / XP / levels | built, **unreviewed** | in-memory, gates nothing |
| Crafting materials (earn side) | built, **unreviewed** | basic on cast, rare on kill; shown in inventory |
| Rod crafting + multi-rod equip | built, **unreviewed** | `C` menu; 3 new rods, mats+coins+level recipes |
| Weapon crafting + multi-weapon equip | built, **unreviewed** | `C` menu Weapons tab; club (Lv 3), blade (Lv 7), Shellcrusher (Rare, Lv 9), Drowncleaver (Epic, Lv 13) — all four are WeaponPack meshes (procedural club/blade kept as pre-import fallback; import pending), Blender swing clips |
| **UI overhaul** (2026-08-23) | built, **unreviewed** | one kit (`Client/UI/Kit`, `Describe`, `ItemDetail`, new `Theme`); every menu + HUD rebuilt on it; no icons uploaded yet — tiles show monograms until rows get `icon` ids |
| Persistence | **built 2026-08-25**, unreviewed | `DataService` (first in ORDER): UpdateAsync session locking, 60s autosave, BindToClose; slices from Progression/Inventory/Material/Bait services + `Cleared_*`/`Heart_*` attributes |
| **Drivable boat + tier ladder** (revamp S3, 2026-08-25) | built, **unreviewed** | `Boats.luau` 6 tiers, `BoatModel` (procedural + BoatPack mesh path, TrophyShelf mounts), `BoatService`/`BoatController` (R to summon, driver-owned physics, seaworthiness DoT), Boat tab in `C` menu, `mayEnter` travel gates + containment sweep — see "The boat" |
| **Ambient spawner + raids + island events** (revamp S3, 2026-08-25) | built, **unreviewed** | `SpawnerService`/`RaidService`/`RaidHudController`/`EruptionService` + `Hazards` extraction + `noLinger`; rosters on the tropical/swamp/volcano Islands entries — see "Spawner, raids, island events" |
| **Ranged engine + flyers + Blackmire Fen** (revamp S2, 2026-08-25) | built, **unreviewed / imports pending** | server-authoritative hitscan (`ShotAim`, `RequestShoot`/`ShotFired`, token bucket + mags/reloads), `ranged` Weapon block, `RangedController`/`RangedFxController`, `flyer`+`skythief` archetypes, swamp kit + Old Gnashroot; the final 6-island `Islands.order` |
| **Islands 3/5/6 + volcano final re-gate** (revamp S4, 2026-08-26) | built, **unreviewed / imports pending** | Frostmaw Reach (`ice`), Gloomtrench (`gloom`), Wreckwater (`wreck`): full 5/5/3/4 kits, 38 creatures + Rimefang/Noctyss/Admiral Wrack, ambient+raid rosters; volcano re-gated L22-28 rewards ×6, Pyrelisk 40k/gate 28 — see "The S4 islands" |
| **The Maelstrom + the Kraken** (revamp S4, 2026-08-26) | built, **unreviewed** | procedural site (no mesh), `Maelstrom_Water` roster, six-hearts+final-boat gates, Kraken 130k with tentacle ring/exposure windows/`rangedOnly` head, finale banner — see "The finale" |
| **Trophy Hall + boat shelf + weather** (revamp S4, 2026-08-26) | built, **unreviewed** | `TrophyController` (H), `TrophyShelfController` (heart orbs on the boat), `WeatherService`/`WeatherController` (ice blizzards + gloom perpetual dark w/ lantern rods) |
| **Review rounds 1-3** (2026-08-26) | **closed, all lanes** | every confirmed finding fixed and committed — see the fix ledger in "The post-ship days" |
| **Island visual overhaul, rounds 1+2** (2026-08-26→27) | done, in the imported pack | every non-tropical island redesigned to be theme-distinct; Frostmaw went a THIRD round (rejected berg → soft glacier → cornice); pack-authority re-key rule + `meshBottom` born here |
| **Bipedal creature redesign** (2026-08-26) | done, re-import landed | every humanoid in the CreaturePack got a silhouette, gear and a weapon (0903783) |
| **Guns rebuilt as guns** (2026-08-27) | done, imported | 15 recognizable firearm silhouettes + the separable `Mag`/`Action`/`Sight`/`Muzzle` part contract + ranged hold poses (fd9c861/c67b5dc/7cc0a90) |
| **Melee arsenal revamp** (2026-08-27) | built; `weapon.glb` re-import pending | 15 post-cove melee models rebuilt + six per-family swing classes (f309c40/1c1132b) — see "The post-ship days" |
| **Per-gun reload animations** (2026-08-27) | built, live (code-side) | multi-track clip system: visible mag handling by an appearing left hand, revolver cylinder work, bow nocking... one unique clip per gun (a738a16/4b60215) |
| **Real projectiles** (2026-08-27) | built, live | bow/crossbow/harpooner fly their own `_Mag` mesh, not tracers (`ranged.projectile`, 648ba2c) |
| **Voyage-arc map redesign** (2026-08-27) | built, **unreviewed** | islands scattered across one huge sea (legs 4,000→8,700 studs, arc around the cove), boat speeds/seaworthiness retuned per leg, sailing compass on the helm — see "The voyage-arc map" |
| **Boss redesign: 6 unique movesets + gimmicks + models** (2026-08-27) | built, **unreviewed / creatures.glb re-import pending** | e84f7e9 (engine+data+client) + ba93efb (art): every post-cove boss has its own attack book on a new parameterized boss arsenal, a one-of-a-kind gimmick, and a bespoke Blender model — see "The boss redesign" |
| **SWAMP RESTART, step 1: bare grey landform** (2026-08-27) | built, **awaiting Studio review / island_pack.glb re-import pending** | 7165cf4: the shipped fen REJECTED and deleted wholesale; `build_swamp` now emits only a grey `Swamp_Base` dome — step-by-step rebuild, each step reviewed before the next — see "The swamp restart" |
| More archetypes (charger/spitter), style/juggle, arena | not started | see Known gaps |

### Manual Studio steps — check these first

All meshes go through Studio's Import once and the result is checked in as
`assets/Assets.rbxm` (see "Asset pipelines"). **The running ledger of which
`.glb`s currently owe a re-import is `docs/import-checklist.md`** — trust
it over file dates; as of this rewrite three are owed: `weapon.glb`
(melee rebuild 1c1132b), `rod.glb` (rod round be82f72), and
`island_pack.glb` (the swamp declutter + pine-fix pack 384c971 postdates
the last island import). If
a catch spawns as a grey ball and Output warns about `FishPack`, the pack
model is missing or misnamed: it must be `ReplicatedStorage/Assets/FishPack`
(the old single `Fish` model is unused and can be deleted). If the species
shapes look off, that's a `SPECIES` tuning job in `fish_gen.py`, then
re-import + re-export the rbxm.

## Systems

### World: island, dock, spawn, ocean

- The island is a **Blender-generated low-poly mesh** (`assets/island_gen.py`
  → `island.glb`), not Roblox parts. Objects (`Island_Base` ×3 materials,
  `Island_Rocks`, `Palm_*`, `Island_Bushes`, `Dock_Planks`, `Dock_Posts`,
  `Island_Foam`) are recoloured **by name in code** (`WorldService.MESH_COLOR`)
  because the importer's material handling isn't trusted. Iterated three
  times on reference images; current look was approved.
- **Dock** is part of the island mesh (`build_dock()`): 52 studs long, 10
  wide, 18×13 end square, continuous planks, bollards at one height. Runs out
  along Roblox +Z from the north beach. `World.luau`'s `DOCK_*` / `DECK_Y`
  mirror the generator's constants and **must be kept in sync by hand** (the
  script prints `DOCK_TOP`). `WorldService` anchors the island's XZ on the
  `Island_Base` part, not the whole model's bounds, so the dock doesn't drag
  it off-centre.
- **Foam rim** (`build_foam()`, object `Island_Foam`): a thin white band
  following the real shoreline, ~0.8 studs visible (`FOAM_WIDTH` 2.8 minus
  what the sand slope hides), collars around submerged dock posts,
  non-collidable. The user wanted "a really thin white line"; it's there.
- **Spawn** is the south beach (Roblox −Z); the dock is north (+Z), so a new
  player walks across the island past the arch. `WorldService.buildSpawn`
  probes straight down for the real sand height (`World.SPAWN_PROBE_HEIGHT`)
  and `removeTemplateLeftovers()` destroys every `SpawnLocation` that isn't
  ours and the template `Baseplate` (its top was coplanar with the water and
  z-fought as a blue grid). If someone spawns under the island now, the
  suspect is the mesh's collision fidelity, not the spawn code.
- **Ocean** is one flat part at `World.WATER_Y` (0) with **one** scrolling
  `Texture` layer of pale wavy "caustic" lines (`assets/water_gen.py` →
  `water.png`, uploaded as `Ocean.TEXTURE_ID = 132930391524358`), tinted and
  faded code-side via `Ocean.LAYERS`, scrolled by `OceanController`.
  Four passes of user feedback landed on: darker water — now
  `(18, 88, 150)` — one layer only, slow drift, no foam pulse.
  `WorldService.buildOcean` warns with upload steps if the id is 0.
- **Tide (2026-08-22):** the water is no longer stagnant — it runs up the
  beach and back. **No new geometry, no texture work**: the beach's own slope
  does it. `OceanController` raises/lowers the flat water plane by
  `Ocean.TIDE.HEIGHT` (0.35 studs) on a swell+chop sine, and because the sand
  near the shoreline rises only ~0.8 studs over ~11, that sweeps the water's
  edge several studs inland over the darker wet-sand band and onto the pale
  dry sand, then back out. The foam rim rides along: it's a separate MeshPart,
  so it's lifted by the same amount **and scaled inward** by `TIDE.REACH`
  (4.5 studs) — without the scale the white line would strand at its baked
  radius while the water moved past it. Knobs in `Ocean.TIDE`
  (`HEIGHT`/`REACH`/`PERIOD`/`CHOP_PERIOD`/`CHOP`); keep `REACH ≈ HEIGHT /
  0.07` or foam drifts off the water's edge.
  - **Client-only and visual-only, deliberately.** Replicating a 3000-stud
    part's CFrame per frame would be waste, and the server never moves it so
    replication doesn't fight the local set. **Gameplay still treats
    `World.WATER_Y` as THE waterline** — cast landings, creature grounding,
    splash heights all use it, and the tide is small enough that the visual
    surface never visibly disagrees. Anything water-adjacent added later
    should key off `World.WATER_Y`, not the ocean part's live position.
  - **The rim moves VERTICALLY only — never scale it.** Two attempts to make
    the foam chase the water's edge across the sand by scaling the MeshPart
    both failed the same way: `Size` scales a mesh about its OWN bounding-box
    centre, and the foam mesh's box is dragged off-island by the dock-post
    collars baked into it, so scaling slid the whole ring off the coastline
    and left the collars floating on open water as white blobs (user,
    2026-08-22: "the foam and sand doesn't line up"). Lifting alone keeps
    every part of the rim exactly where it was authored. A clone-the-foam
    trick for a moving wet-sand line died with it (it needed the same
    scaling).
  - **To make the shoreline lines genuinely sweep inland**, the fix is in the
    mesh, not the code: regenerate `assets/island_gen.py` with the foam rim
    centred on the island and the post collars split into their own object
    (and, for a moving dark line, a wet-sand ring emitted the same way), then
    re-import + re-export `Assets.rbxm`. Until then keep `TIDE.HEIGHT` modest
    so the water's edge never wanders far from where the rim is baked.
  - If the rim is ever missing, `OceanController` warns after 10 s rather
    than failing silently — the water would still rise and fall while the
    shoreline lines sat still, which reads as "the tide is broken".
- Arena deck from the plan is **not built** and may never be — with the
  fishing pivot the dock's end square may be enough of a stage. Constants
  (`ARENA_*`) remain in `World.luau` unused. Ask before building it.

### Volcano REDESIGN: tall stratovolcano, dock at the bottom (2026-08-24)

**Supersedes the rim-top design below** (user: "new volcano map… dramatic and
tall jagged volcano with lava flowing everywhere and then the user fishes off
of a dock on the bottom… really really really tall"). Built on macOS —
Blender 5.2 at `/Applications/Blender.app/Contents/MacOS/Blender` (installed
via `brew install --cask blender`; the Windows path in the pipeline notes is
stale on this machine).

- **The shape** (`island_gen.py` `ISLANDS.volcano` overrides): ~935-stud
  concave stratovolcano, radius still 640 (Roblox 2048 import cap; the
  generator flags anything over the limit). **Asymmetric broken ridgeline**
  (2026-08-24 spec pass): new `PEAK_JAG`/`PEAK_TERMS` generator globals
  modulate the upper cone per angle (lip ranges ~885–999, zeroed across
  each notch window so no gash seals), wide ragged crater mouth (~150-stud
  lava lake at 838, lip u 0.155) with a crown of tall obsidian spires;
  near-vertical craggy flanks (CRAG 56); flat walkable **ash apron at sea
  level** (u 0.70–1.0, crag suppressed there via RIM_FLAT). Shore slope
  matches the starter (~0.5 studs rise per 10 at the waterline) so the
  tide reads. `print_volcano_handoff()` prints the Luau wiring numbers on
  every build (dock start/end + plank top, spawn ground Y, rim
  height/radius, apron shelf height).
- **Lava**: 5 NOTCHES gash the summit lip; one full-flank WIDE flow pours
  from each (`_lava_flow`, 40 steps, width 4→15) and spreads across the
  base as a **cascade of 2–3 broad pools** (17–28 radius) stepping outward
  and downhill, joined by wide spill strips — molten sheets threading the
  apron between the rocks and dead trees (avoidance pads are ~1 stud so
  props crowd the edges). The dock and the sea around it stay plain ocean
  (user, 2026-08-24: no notch faces the dock angle; pool centres cap at
  u 0.955 so lava grazes the far beaches but the chain can't enter the
  sea). Every pool is fishable lava (`waters="volcano"` roster, reached on
  foot); `LAVA_PONDS` records them so the apron scatter keeps clear. All
  lava is ONE `Volcano_Lava` object — the fishing system hit-tests by
  exact name, so never split it. **Flows raycast the base mesh's BVH**
  (centre + both edges, 2.2 clearance): the analytic height disagrees with
  the real mesh by tens of studs (CRAG_RADIAL jitter), which fragmented
  earlier attempts.
- **Dock**: a plain shore jetty into the SEA at the BOTTOM (the tropical
  `build_dock` machinery via DOCK_* overrides — the old rim-pier builder is
  gone), Roblox +Z, starting at r≈527 and running 92 studs past the
  shoreline over open water; deck y 2.6, posts collared by the surf foam
  like the starter's. You fish OCEAN water off it. Object names still
  `Volcano_Dock_Planks/_Posts`.
- **Apron props** (user: "more details of random stuff", then "the base is
  barren… make it enjoyable to walk around" — densified + CLUSTERED into
  landmarks, not a uniform sprinkle) — five single-material objects, all
  raycast-seated, all skipping the dock corridor and the ponds:
  `Volcano_DeadTrees` (RENAMED from Volcano_Snags 2026-08-24, spec-required
  name; 13 burnt GROVES + loners, ~100 trees, trunks **35–75 studs** —
  user asked for 5× after 8–18 read "way too small" against the mountain;
  `add_cone` trunks + limbs, M_Charred), `Volcano_Basalt` (24 hex column
  clusters, M_Basalt), `Volcano_Vents` (13 fumarole cones, most with a
  smaller companion, M_Cinder), `Volcano_Scree` (~340 small half-buried
  box chunks — the ground clutter, M_Obsidian), `Volcano_Dunes` (26 soft
  ash drifts to roll the flat ground, M_VolAsh); plus ~230 boulders and 50
  obsidian shard fangs in `Volcano_Rocks`. New `add_cone`/`cone_axis`
  helpers. **WorldService.MESH_COLOR gained entries for all five new
  names** — a new prop object is invisible-grey without one. A 4th preview
  shot `_apron.png` stands on the apron looking along the base. ~16.5k
  pre-triangulation polys for the island (was 6k).
- **The ocean already covers the volcano** — `WorldService.oceanSpan` sizes
  the one shared plane past the farthest PLACED island (+500 margin), and
  `init` places islands BEFORE building the ocean (verified 2026-08-24,
  comment at the init call), so the sea surrounds the volcano the moment
  its mesh import exists. "No ocean / no dock / barren base" seen in-game
  before that is the OLD imported mesh, not a code gap — the user has hit
  this three times running; the re-import is the unblocking step. The raw
  .glb never contains water (neither does the starter's).
- **Scatter density after the "still barren" round (2026-08-24):** ~300
  apron boulders (up to 11 studs), 70 obsidian shards, 460 scree chunks,
  32 dunes, dock upsized to 110 × 14 (end 20 × 30). Whole island ~20k
  pre-triangulation polys / ~26.5k with the tropical island in the pack —
  each object stays under Roblox's per-mesh triangle limit; the count is
  printed per pack build.
- **Wiring** (`Islands.luau`): `rim`/`pier` blocks DELETED — the playable
  apron is ocean-bounded exactly like the starter, so WorldService's rim
  sampler/walls/`clampToBounds` are dormant (the machinery survives for a
  future island). `castRangeMult` removed entirely (sea fishing off the
  dock; ponds fished standing beside them). Spawn on the apron right in
  front of the dock (3000, 12, 505). `Tuning.Cast` comment updated.
  stylua/selene/rojo all green.
- **NEW `NOTCH_BAND` generator global**: where NOTCHES carve, decoupled from
  RIM_FLAT (which now marks the apron); volcano sets it to the summit lip.
  `_drop_to_ground` now casts from y 1500 (was 500 — under the new peak).
- **Previews**: `island_volcano_preview.png` (overview), `_dock.png`
  (standing at sea past the dock: planks over open water, prop-littered
  apron and the volcano behind), `_tower.png` (full spire from the sea).
  Preview's second camera is now the dock vantage (the rim shot is gone).
- **Manual steps owed (user, in Studio)**: re-import `island_pack.glb` (or
  `island_volcano.glb`) so `Assets/Volcano` is the new mesh, set
  PreciseConvexDecomposition on the Volcano parts, delete the old Volcano
  model, re-export `Assets.rbxm`, restart `rojo serve`.
- **Unreviewed in Studio.** Likely tuning asks: flow width/count, delta
  size, crag amplitude, dock length, spawn spot, castRangeMult.

### Volcano: fishable lava, the rim as the playable area (2026-08-23, SUPERSEDED — kept for the machinery notes)

User: "don't allow the fish and creatures to leave the rim of the volcano…
allow users to fish from the rim itself so increase the casting range…
make sure users can't leave the rim and the lava itself."

- **Fishable surfaces** are `World.FISHABLE_NAMES` (`Ocean`, `Volcano_Lava`).
  `CastAim.aim` / `isWater` accept either and return the landing **with
  that surface's Y** (`WATER_Y` for the ocean, the hit's height for lava);
  `isWater` also returns the probed Y so `FishingService.validateLanding`
  snaps the claim onto the real surface (the client's Y is a hint only).
  `CastAim.rangeFor(rodData, from)` multiplies by
  `Islands.castRangeMultAt(from)` (volcano `castRangeMult = 3` → 135 studs;
  the rod's `castRange` perk still multiplies on top). Downstream the
  landing's Y is used everywhere: the bobber/splash/ripples
  (`FishingController`), the throw start + no-target rest
  (`CreatureService.spawn`), the breach splash (`CreatureVfxController`
  probes the surface). `groundedPos` keeps a creature's height when nothing
  solid is under it (lava is non-collidable) instead of dropping to the
  waterline.
- **Bounds** (`WorldService` "Island bounds"): for an island with a `rim`
  block, boot samples the placed mesh — `rim.samples` angles × a radial
  march of down-probes against the `*_Base` parts — for the inner/outer
  radius of ground within `rim.tolerance` of `rim.height` (nil at the
  spillway notches). Walls (1-stud, `wallHeight`, invisible, `CanCollide`
  on, **`CanQuery` off**) follow both edges, radial closers seal the
  notches, and the **pier** (found from `Volcano_Dock_Planks`' position —
  it's radial — with `Islands.pier` dims) gets a gap in the inner wall plus
  railings round its deck and end platform. `WorldService.clampToBounds
  (position)` pulls a point into band ∪ pier; `CreatureService.groundedPos`
  runs every creature position through it, and `spawn` clamps the throw's
  landing. `WorldService.inlandDirection(target)` — "behind the player" —
  is outward from the crater centre on a bounded island (toward the centre
  is the lava), toward the origin on the starter.
- **The barriers are ONE-WAY** (user, 2026-08-23). Three separate
  mechanisms, each doing one job: casts pass through because every barrier
  is `CanQuery = false` **and** `CastAim` hops parts named `RimWall` /
  `PierRail` / `*Dock*` by name (`World.CAST_PASS_THROUGH_NAMES`);
  creatures pass through because barriers are in the
  `World.BARRIER_COLLISION_GROUP` and every creature part is in
  `World.CREATURE_COLLISION_GROUP` (registered in `WorldService.init`, set
  non-collidable) - a catch thrown in off the lava used to bounce off an
  invisible wall mid-arc; and creatures can't LEAVE because of
  `clampToBounds`, not because of any wall. Players are in the default
  group and are stopped normally. A barrier's collision group is assigned
  after creation inside a `pcall`: assigning an unregistered group throws,
  and inside world-building that would take the whole server boot down.
- **The pier's railings** (`buildPierRailings`) are continuous full-height
  walls down each side, a step out where the wide end platform starts, and
  a cap across the far end - **nothing on the stretch that still sits on the
  rim** (detected as "there is still rim-height ground beside the deck").
  Widths are the **median** of the measured per-bin half-widths, not the
  max: the bin straddling the walkway/platform join reads platform-wide and
  pushed the walkway's railing metres out over the lava.
- **Not done / to watch:** no player "you're out of bounds" net beyond the
  walls (the under-map net covers falling through); creatures caught from
  the pier's end land on the pier behind the player (clamped); the rim
  rocks are collidable and walked among by design (9b). `CastAim` prints one
  throttled line naming whatever stopped a refused cast - remove it once the
  volcano's casting is confirmed good.

### The boat (revamp S3, 2026-08-25, unreviewed)

- **Owning a boat is the replicated `BoatTier` Player attribute** (0 = none;
  DataService persists it as `profile.boatTier`), not an inventory id.
  `Shared/Data/Boats.luau` is the 6-tier ladder (Cove Skiff → Stormbreaker
  Keel, the plan's boat table verbatim); tiers 2–6 craft through the
  item-agnostic CraftingService (`isBoat` branch demands exactly the next
  tier up), tier 1 is NEVER crafted — `BoatService` watches the
  `Heart_brinejaw` attribute and grants it on the kill AND on load (a
  returning player who beat Brinejaw pre-boats gets back-filled). The `C`
  menu grew a **Boat tab** (current + next rung unveiled, the rest "?").
- **`BoatModel.build(row)`** (Shared/Modules, WeaponModel-style): the ONLY
  collidable part is `Boat_Collider`, an invisible box sized from the row
  (beam × draft+deckHeight × length, bow toward −Z, origin at the waterline);
  all visuals weld to it massless/no-collide — procedural hull by default,
  `Assets/BoatPack` variant meshes when imported (`assets/boat_gen.py`,
  suffix contract `<Variant>_Hull/_Deck/_Bow/_Mast/_Sail/_Rail/_Trim/
  _Lantern/_Figurehead/_Shelf/_Helm`; `_Helm` marks the VehicleSeat spot and
  is consumed). `TrophyShelf` child Model carries Attachments
  `HeartMount1..6` — TrophyController's shelf renderer mounts boss hearts
  there off the OWNER's `Heart_*` attrs (owner = the boat Model's
  `OwnerUserId` attribute).
- **Driving is client-owned physics**: `R` (or the touch BOAT button)
  summons/recalls to the nearest shoreline (`WorldService.boatLaunchCFrame` —
  outward past `radius + 30`); sitting in your own `Boat_Seat` hands the
  hull's network ownership to you and `BoatController` steers the two
  constraints in the collider (`Boat_Move` LinearVelocity: heading × speed +
  a P-controlled vertical component; `Boat_Align`: upright + integrated yaw).
  **Y is held at `World.WATER_Y` + rest height + bob — NEVER the
  tide-animated visual plane.** Only the owner may drive (strangers are
  bounced from the seat); an emptied seat re-anchors flat at the waterline
  after `PARK_SNAP_DELAY`. Knobs in `Tuning.Boat`.
- **Collision groups**: ocean slab in `Water`, every boat part in `Boat`;
  Water↔Boat and Creature↔Boat non-collidable (hull floats by code and a
  thrown catch passes through a parked boat); players collide with both as
  before. Registered in `WorldService.registerCollisionGroups`.
- **Seaworthiness**: BoatService's 1s loop measures
  `WorldService.openSeaDistance` (distance past the shoreline of the nearest
  island the OWNER passes `mayEnter` for) against the row's number; beyond
  it the hull takes ramping DoT (`HullHealth` attribute on the boat Model),
  one warning banner, then a sink — occupants dumped, wreck despawns. A
  fresh summon at shore is a free repair.
- **Travel gates are ONE rule now**: `WorldService.mayEnter(player,
  islandId)` = exists + placed + level + previous island's `Cleared_` +
  **`BoatTier >= order index − 1`**; the teleport menu funnels through it,
  and the 0.5s loop's **containment sweep** bounces any non-admin standing
  inside a locked island's footprint to the nearest allowed island — closing
  the walk-on-the-solid-ocean hole, so sailing needs no gate checks of its
  own. The teleport menu stays as fast travel.

### Spawner, raids, island events (revamp S3, 2026-08-25, unreviewed)

- **`SpawnerService`** — the first non-fishing spawns. Rosters live on
  `Islands.items[id].ambient` (`rows` weighted, `maxAlive`, `interval`,
  optional `ring`); every `Tuning.Spawner.TICK` it stands a rolled hostile
  up on solid ground 60–100 studs from a random player on that island
  (down-probe vs `Workspace.World`, Ocean hits rejected — land only), no
  throw target, `{ ambient = true }`. LINGER is the cleanup; global cap
  `GLOBAL_CAP` (40). **`setBias(islandId, archetype, mult)` /
  `clearBias(islandId)`** is the event hook — WeatherService's blizzard
  biases ice flyers ×3 through it. `groundPointNear` / `playersOn` are
  shared helpers (RaidService and EruptionService use them).
- **`RaidService`** — per-island `idle → announced → wave k of N →
  cleared|failed` off `Islands.items[id].raid` (interval/announce/waves/
  timeLimit/reward/bountyMult; defaults in `Tuning.Raid`). Raid mobs spawn
  with `extra = { raid = islandId, noLinger = true, suppressDrops = true,
  bounty = 0.35 }`: **`creature.noLinger` is now a first-class flag in the
  despawn sweep** (boss/friendly-style exemption — b8's Kraken tentacles
  reuse it verbatim), `suppressDrops` kills material AND rare-item drops
  (DropService gained the guard MaterialService already had), `bounty`
  scales kill coins/XP down so raids can't out-earn fishing — the payday is
  the clear reward, paid to every `participants` killer (BossService shape).
  A failed/abandoned raid **releases** its mobs (noLinger cleared, fought
  clock zeroed) so nothing immortal squats the beach. One `RaidState`
  broadcast per second while active; `RaidHudController` filters to the
  island the local player stands on (`Islands.islandAt`, the shared
  footprint rule).
- **`Hazards.luau`** (Server/Modules) — `fireEvent` +
  `damagePlayersInRadius` extracted from CreatureService (which now
  delegates); raids and events hurt players by exactly the creature rule.
- **`EruptionService`** — the volcano's bomb windows: every 5–8 min with
  someone on the apron, 24s of lava bombs (one per 1.7s near a random
  player, ring 5–26 so a direct hit can't be pre-placed), each fully
  telegraphed — `telegraph` ring + `spit` glob falling from the summit on
  the same 1.25s clock, then `damagePlayersInRadius` + `explode`. **No new
  client code: it speaks the existing CreatureEvent vocabulary.** Start/stop
  also goes out on `WorldEvent` for ambience.
- **`WeatherService` / `WeatherController`** (b8's, wired into the ORDERs
  with S3): timed blizzard windows on the ice island over the same
  `WorldEvent` remote ({ kind, islandId, active }), client fog/snow +
  spawner flyer bias; the gloom island's perpetual dark is client-only (no
  remote — standing there IS the event).
### The S4 islands: Frostmaw Reach, Gloomtrench, Wreckwater (2026-08-26, unreviewed)

All three shipped as pure data on the S2/S3 machinery — no new engine for
the islands themselves. Numbers and rosters follow `docs/revamp-plan.md`'s
island tables verbatim; the ledger of record stays that file.

- **Fishable surfaces** (the `World.FISHABLE_NAMES`/`WATERS_BY_PART`
  contract, one object each, never split): `Frostmaw_IceHoles` → `"ice"`
  (fixed pre-cut holes in the sheet — drilling/refreezing deliberately NOT
  built), `Gloomtrench_DarkWater` → `"gloom"`, `Wreckwater_Bay` →
  `"wreck"`. The sea off every dock stays plain ocean.
- **Kits**: 5 rods / 5 weapons / 3 baits / 4 signature materials each, gates
  at L15-21 / L29-35 / L36-42, rewards ×3.5 / ×10 / ×16. Each Legendary
  rod+weapon is heart-gated (`requiresHearts`); each island's third bait
  summons its boss (Glacier's Call / Trench Mother's Call / Admiral's
  Summons). **Every rod sits on the RodPack's shared 7.0-length/0.95-grip
  frame** — the generator builds all variants on one frame, so a row that
  deviates puts the mesh wrong in the hand and breaks the tip tracker.
- **Bosses**: Rimefang (26k), Noctyss (60k; enrage douses her lure
  client-side), Admiral Wrack (85k). **Movesets described here were
  REPLACED by the 2026-08-27 boss redesign** — see "The boss redesign"
  section for the current kits. All three arenas
  sit off the dock end (the Pyrelisk stable-spot precedent — inland pools
  move with every mesh regen) except Wrack's, in the island's stable
  central bay at offset (0,0,-20).
- **Ambient + raid rosters** ride the Islands entries (5a's S3 shape);
  Wreckwater's raids are the plan's boarding raids.
- **Volcano final re-gate**: rods L22/23/25/26/28, baits L23/25/28, kept
  melee pair re-damaged to sit with the guns, creature healths ×2.7 (≈×6
  the island-1 baseline), rewards ×6, Phoenix 6k HP as the Legendary chase,
  Pyrelisk 40k HP / gate L28. The interim-band comments are struck.
- **Weather** (see the S3 bullet above for the plumbing): blizzards bias
  the ice spawner toward `flyer`+`skythief` ×3; the gloom dark gives the
  character a personal lamp, and holding a lantern rod (`lanternline_rod` /
  `gloomheart_rod`) doubles both the lamp and the fog distance —
  the island's light-management mechanic in its simplest playable form.

### The finale: the Maelstrom and the Kraken (2026-08-26, unreviewed)

- **The site** (`WorldService.buildMaelstromSite`): `Islands.items
  .maelstrom` is `site = true`, OUT of `Islands.order` (the linear
  `Cleared_` chain never sees it), and has NO mesh — the arena is parts,
  deterministically seeded: the `Maelstrom_Water` whirlpool disc
  (fishable, `"maelstrom"` roster), nine jagged platforms at r 38-52
  (inside tentacle reach by design), the +Z spawn platform, outer spires.
  It is marked `placed` so the shared ocean spans to (18000,0,0) and 5a's
  containment sweep doesn't eject the raid.
- **Gates, three layers deep**: the travel menu veils the site card until
  all six `Heart_*` attrs (IslandsController); `WorldService.mayEnter`'s
  site branch demands the six hearts AND the final boat tier (Stormbreaker
  Keel); Kraken's Call itself is L48 + `requiresHearts` all six (checked,
  never spent), and `BossService.qualifies` re-checks `gate.hearts` at the
  summon. `Tuning.Rarity` never rolls the kraken rows (rarity "Boss").
- **The fight** (engine in `CreatureService`): the Bosses entry's `parts`
  block plants a ring of 6 `kraken_tentacle` rows (`archetype "tentacle"` —
  planted, swaying, slamming a telegraphed 12-stud ring; knockback/launch
  0; `noLinger` + suppressed drops + 0.5 bounty) as the boss finishes
  rising. The head is `rangedOnly` (the MELEE target pick passes
  `inRange`'s new `opts.skipRangedOnly`; guns/`raycastNearest` still
  connect) and `vulnerableWhen = "partsDown"` (`damage()` refuses while
  `partsAlive > 0`; Brine Rot's `ignoreUntargetable` burns through, same
  ruling as a dive). `kill()` counts the ring down and fires `"exposed"`
  on the last arm ("THE MAW IS EXPOSED" card); `parts.regrow` (24s) later
  the ring re-plants with a `"regrow"` card; a dying boss takes its
  surviving arms with it. Killing the head sets `Heart_kraken` +
  `Cleared_maelstrom` and fires `bossDown` with `finale = true` — the
  gold "THE MAELSTROM FALLS SILENT" card, no next-island line (the
  `unlocks` lookup is nil-safe for out-of-order islands).
- **Trophy Hall** (`TrophyController`, `H` / the bottom-left HALL button):
  one card per boss in saga order (derived from `Islands.order` + gate
  level, so the Kraken appended itself when its entry landed), lit heart
  tile vs dimmed silhouette off the `Heart_*` attrs, heart-count subtitle.
  Pure reader, no remotes. **Boat shelf** (`TrophyShelfController`):
  decorates any boat's `TrophyShelf` mounts (`HeartMount1..6`, bow→stern)
  with neon heart orbs for the boat OWNER's hearts (`OwnerUserId` attr,
  stamped by `BoatService.summon`). The kraken heart has no mount — it IS
  the run's end.
- **Deliberate scope calls**: no maelstrom ambient/raid blocks (the finale
  stays a boss site); the whirlpool doesn't spin (a LavaController-style
  swirl is the one cosmetic TODO); tentacle ring/aggro numbers are first
  guesses — expect a tuning round.

### The Maelstrom built for real (2026-08-27, import owed, unreviewed)

User: "build the complete maelstrom island, it is completely unfinished."
The site got an AUTHORED mesh — `island_gen.py` grew a `maelstrom` entry
(builders after build_wreckwater, reusing the `_wr_*` ship toolkit) exported
standalone as `assets/island_maelstrom.glb` → import as `Assets/Maelstrom`
(checklist row 1b; also appended to ISLAND_ORDER so the next pack regen
bundles it). Deliberately NOT a landmass: `Maelstrom_Base` is a fully
SUBMERGED storm-shoal (dark shallows dishing into a vortex bowl under the
whirlpool), and everything walkable is a basalt stack.

- **Contracts held** (the mesh section's header comment is the ledger): the
  `Maelstrom_Water` disc (r75) stays PROCEDURAL — buildMaelstromSite always
  builds it, MaelstromVfxController spins it BY NAME as a DIRECT child of
  the "Maelstrom" instance — and nothing is authored inside r<80, so the
  disc, casting lanes and the Kraken's rise stay clear. Fight stacks ring
  r 38-52 with FLAT walkable caps at y 3.6-6.0 (arena r34, tentacle ring
  r26 per the e84f7e9 kraken rewrite); the spawn stack is at rel +Z 44, top
  exactly 6.0 (the entry's spawn fallback). The 270° bearing (Roblox +Z,
  home's direction) is a clear sailing lane through both spire belts.
- **The dressing**: two belts of storm-teeth + three ~90-118-stud TITAN
  FANGS leaning toward the maw (the finale's from-miles-out silhouette);
  a five-ship doomed fleet on the spiral (bow/stern/ribcage sections, each
  yawed just off tangent so the fleet reads as circling in) + two drowned
  rib rings; three colossal snapped anchor chains arcing off the tallest
  teeth, dying at r86; a flotsam ring; reef rocks seated against the
  WATERLINE (first build sat them on the seabed and drowned them — review
  catch, like the platform column bulging through its cap; both fixed
  against rendered previews before commit).
- **Wiring**: `buildMaelstromSite` now places the mesh via `placeIsland`
  when `Assets/Maelstrom` exists (full MESH_COLOR/collide/meshBottom
  treatment; the water disc is parented INTO the placed model) and keeps
  the old procedural ring as the pre-import fallback. Islands entry gained
  `model = "Maelstrom"` + `meshBottom = -11.95` (keels/columns dip past the
  -9 skirt — re-key from the HANDOFF line on any regen; the standalone
  build prints it too, not just the pack). Wrecks/Sails/Chains/Debris/
  StormGlow are NON_COLLIDE (the SeaHulks boat ruling); Platforms/Spires/
  Rocks/Base collide — **PreciseConvexDecomposition on Base + Platforms at
  import** (the fight floor). `Maelstrom_StormGlow` is Neon, electric cyan.
- **Generator infrastructure added**: `PREVIEW_SHOTS` override (extra named
  preview cameras per island — maelstrom renders `_arena` and `_approach`
  shots); the maelstrom ISLANDS entry sets EVERY shape key explicitly (the
  configure() no-reset rule from the swamp restart — it builds last, after
  wreck's override set).
- **Likely tuning asks**: spire/titan counts + heights, wreck placement,
  glow density, platform cap sizes, the shoal's visible shallowness.

### The post-ship days (2026-08-26 → 27, all unreviewed-in-Studio unless noted)

The revamp shipped, the user imported everything, the game booted end to
end for the first time — and then the real iteration started. Everything
below happened in roughly 48 hours across a rotating multi-session fleet
(one coordinator arbitrating lanes, heavy art/animation authored by
dedicated Opus subagents, every landing gated on the four commands +
review). The pattern that stuck: **orchestrator session + authoring
agent + a human-visible render reviewed BEFORE commit**, and for art, a
**three-lane blind-gate protocol** (a non-author session measures, not
eyeballs, the claimed invariants) as the QA standard.

- **First boot + the import epoch.** All six packs imported
  (`docs/import-checklist.md` — its ledger is the running truth for what
  re-imports are owed). Boot-blockers found and fixed the same day: the
  DataStore acquire now pcall-guards at require time (Studio without API
  access used to kill the whole server boot), and the four new islands'
  `<Name>_Base/2/3` primitives got their MESH_COLOR splits (multi-material
  landforms import as numbered parts — without entries they render
  importer-grey; the Island_Base precedent, now applied everywhere).
  **Ambient hostile spawning is OFF by user order**
  (`Tuning.Spawner.AMBIENT_ENABLED = false`, cc7d945): mobs must not just
  appear — raids and fishing are the hostile sources. Don't re-enable
  without the user.
- **Review rounds 1–3 — closed, every lane.** The confirmed-findings fix
  ledger (all committed): S1 persistence save-wipe/load-window (44942f6);
  boat/world hardening ×6 + park-thread races (7383f3b, 6a43db2); raid
  payouts crediting every hitter (b99abee); AoE burst stacking (7b5fb0e);
  per-weapon ammo mirrors / stuck auto-fire / respawn zoom (261bf9c);
  Grave Blunderbuss spread was DEGREES in a RADIANS field — it fired in
  random directions (3be36dc); the four new water surfaces + all foams
  joined NON_COLLIDE via a "_Foam" substring (players would have walked on
  the pools, 39eaeb0); **the weather fog was 100% invisible** — an
  Atmosphere under Lighting makes Roblox ignore legacy `Lighting.Fog*`,
  so WeatherController now drives the Atmosphere itself (gloom density
  0.72→0.58 with a lantern rod; 5d55419 — any future fog work must go
  through the Atmosphere too); the Maelstrom map card reads YOU ARE HERE
  on the site (f44a9c4); and the boss bar re-targets the NEAREST live
  boss and hands over on despawn instead of dying — two bosses can be
  alive on different islands now (9060296).
- **Island visual overhaul, rounds 1 and 2.** User verdict on the shipped
  islands: flat pancakes. Round 1 (pre-restart WIP, committed as the
  1b28763 baseline) reshaped swamp/gloom/volcano/wreck; round 2 was a
  four-lane fleet pass making each island unmistakable (mangrove-roof
  fen, more-lava volcano, open-sea wreck graveyard, gloom overhaul), all
  collected in the 5904cf0 pack. **Frostmaw took three rounds of its
  own**: my towering-berg build was REJECTED by the user ("shouldn't be
  jagged" — reference images wanted soft chunky glacial forms), replaced
  by the soft-glacier rebuild and then the glacial-cornice iteration
  (d64d120→dfc039f). Its mesh objects are now Berg / Arch / Walls /
  Terraces / Crystals / PineSnow / Pines / DeadTrees / SnowMounds /
  ShardLitter / SnowCaps, with the four big forms rendered
  `Enum.Material.Ice` (the one non-SmoothPlastic/Neon material in
  MESH_MATERIAL). Two engine-side rules were born here, both BINDING:
  **(1) the pack build is the authority for geometry keys** — after any
  island regen, re-key `Islands.luau` spawns / `Bosses.luau` arenas from
  the PACK build's printed `HANDOFF` lines, never a solo-island build
  (cross-island module state drifts low decimals; 682f282 re-keyed the
  swamp spawn to Z=130 and moved Old Gnashroot into the fen's new
  interior arena pool at rel (0,0,74) r36); **(2) `meshBottom`** on an
  Islands entry — an island whose authored geometry dips below the -9
  skirt (seabed dunes, sunken keels) must declare its true lowest z, or
  WorldService aligns the bbox bottom on the skirt and the whole island
  floats (the "floating ships and litter" bug, 8eca70e). The ocean also
  learned to span past the farthest shore (f8ddb8d) and every island's
  water now wears the ocean's exact colors (42b73d7). The Frostmaw pines'
  leaf cones were reported disconnected by the user and fixed at the
  generator level: tier height now derives from tier spacing (guaranteed
  1.3-1.55× overlap) and the trunk spans the whole crown (c9695f6).
- **The bipedal cast redesigned** (0903783, imported). Every humanoid in
  the CreaturePack got a real silhouette, gear, and a weapon/prop —
  fleet-split by island; this session's four: FrozenMariner (mid-stride
  whaler with frozen harpoon + rime-rope), BlizzardWraith (legless
  storm-shade shredding into wind-torn tatters, solid crystal
  shard-blade), TempestRevenant (17° haul-lean dragging a barnacled
  anchor on a chain), StormcallerDjinn (cloud-funnel torso, two-handed
  forked lightning-rod, chest core + prong arcs in `_Marks` for the
  in-game Neon). WhirlpoolHorror's buried spiral ridge fixed en route.
  The four-mesh `_Body/_Fins/_Eyes/_Marks` contract held throughout —
  weapons are geometry welded into `_Fins`, glow into `_Marks`.
- **The guns became guns** (fd9c861 → c67b5dc → 7cc0a90, imported). All
  15 rebuilt as recognizable firearms with ranged HOLD POSES (GUN_* pose
  constants beside the melee ones) and a NEW GUN-MESH CONTRACT, binding
  for any future gun: authored butt z=0 → **muzzle exactly at z=LENGTH
  along the bore (+Z)**; four separable parts per gun —
  `<Variant>_Mag` (the magazine/arrow/iron — BY CONTRACT separable so
  reload animations can move it), `_Action` (bolt/lever/cylinder),
  `_Sight`, `_Muzzle` (a tiny marker at the tip consumed as the
  muzzle-flash AND projectile origin); sights on +X — and note the glb
  X-mirror means the in-hand ROLL is +90 for guns where melee uses -90
  (7cc0a90 fixed exactly this: the first import held every gun upside
  down).
- **The melee arsenal revamp** (user: the 15 post-cove weapons were
  "uninteresting" with "odd animations"). Root cause of the odd feel:
  every weapon shared the cove's two clips. Now SIX swing classes, one
  per family, each fitted inside its rows' cooldowns (f309c40): `hack`
  (wrist-snap diagonal — machete/hatchet/Fenreaver), `thrust`
  (coil→level lunge→pinned beat→yank — lances/Piercer/Trenchspike/
  Stormlance), `smash` (hoist→apex hang→crash→buried beat — Glacier
  Maul), `sweep` (flat level cleave carried off the left edge — Boarding
  Axe/Galecleaver/Krakenfang), `flourish` (rising rolled back-cut, wrist
  rolls over into the true diagonal — the three sabers; first clips to
  use the roll channel), `pummel` (translation-dominant piston punch —
  Magma Gauntlets). The cove five keep chop/slash untouched per the
  user. All 15 MODELS rebuilt distinct and island-storied (1c1132b —
  re-import pending); the melee **edge = +X** convention is verified from
  geometry and documented in the generator's melee header; all frames
  unchanged so zero row patches. A latent generator landmine found en
  route: `slab_with_hole` silently rendered folded garbage when a hole
  crossed the profile — it now raises loudly with coordinates, gated by a
  byte-identical pack rebuild (5e4313d).
- **The reload-animation system** (a738a16 + 4b60215, live code-side —
  a real new architecture piece). `assets/gun_reload_anim.py` →
  `Shared/Data/GunReloadAnim.luau`: one MULTI-TRACK clip per gun variant
  — `weapon` (whole viewmodel about the right elbow, the swing
  contract), `mag`/`action` (that part LOCAL about its own home:
  rotation spins in place, translation in camera axes — how a magazine
  drops out of its well and a cylinder rolls on its axle), `hand` (a
  LEFT block arm, built parked off-screen on every gun rig, raised by
  the clips to do the handling; author hand and mag on the same keys —
  that's what sells the grab). WeaponViewmodelController routes
  `Weapon_Mag`/`Weapon_Action` into their own rig groups and plays clips
  **time-scaled to fill the row's server `reloadTime` exactly — the
  visual can never extend or gate the server's window** (binding rule:
  retune the ROW if a choreography needs longer, and rebalance
  DPS if the retune is big). `reloadTime = 0` loaders (bow / crossbow /
  flintlock / harpooner) play theirs after EVERY shot inside 85% of the
  cooldown. All 16 clips are unique and reviewed against rendered
  filmstrips (the pipeline renders per-clip stills; its camera initially
  stared past the gun rendering black frames — fixed).
- **Real projectiles** (648ba2c, live). `ranged.projectile = true` on
  bow/crossbow/harpooner: the flying shot is the weapon's own
  `<Variant>_Mag` mesh — the very arrow the reload nocks — cloned from a
  per-variant pool, accent-recolored, flown nose-first down the existing
  arc with `PivotTo`; procedural arrow fallback pre-import; projectile
  weapons skip the muzzle flash. Guns keep tracers + flash unchanged.
- **The Maelstrom turns** (0f9e15f): `MaelstromVfxController` spins the
  whirlpool disc + a counter-rotating inner layer, client-side, tide/lava
  ruling (server never moves the anchored disc; the cylinder is round so
  casts are untouched; the layer is CanQuery=false).
- **Rod round** (be82f72 — re-import pending): all 25 new-island rods
  rebuilt bespoke across three lanes, no two alike, rows re-colored,
  blind non-author gates with measured z-bounds. Rod frame law, binding:
  the shared 0.95 grip / 7.0 length frame holds, ornament ceiling 7.9
  (the PhoenixAsh precedent), butts hard at z ≥ 0.

### The voyage-arc map (2026-08-27, unreviewed)

User: "huge huge huge ocean where the user will be able to ride their boat
around... place the various islands across this map... they just take the
boat." Pure code/data — NO re-imports owed by this slice.

- **The layout** (`Islands.luau` worldPositions — the only place positions
  live; nothing else hardcoded them, verified by grep): the islands left the
  3000-stud straight line for an ARC that wraps around Starter Cove —
  swamp (3700,1500) → ice (6800,5200) → volcano (11800,2600) →
  gloom (15400,-2700) → wreck (12500,-9500) → maelstrom (4800,-13500).
  Legs grow with the saga: ~4,000 / 4,800 / 5,600 / 6,400 / 7,400 / 8,700
  studs centre-to-centre, each ~90–100s flat out at the boat tier that
  unlocks it (the leg table lives in `Boats.luau`'s header — **move an
  island, re-check it**). The finale sits due south of home, on the cove's
  own horizon. Every island's `spawn` moved with its worldPosition (same
  relative offset; X/Z authoritative, Y still probed). Boss arenas/ambient
  rings are island-relative and moved for free. The ocean auto-sizes
  (`oceanSpan` uses max |X|,|Z| per axis, so negative coords are covered) —
  now ~36k studs square.
- **Boat ladder retune** (`Boats.luau`): speeds 30–52 → **45–85** studs/s
  (open-ocean voyaging pace; ACCELERATION/turnRate untouched) and
  seaworthiness 1750–2600 → **2600–4900**, each tier sized to clear HALF its
  own leg plus ~600 studs of wobble margin (openSeaDistance measures from
  the nearest ENTERABLE shore, and holding the tier makes the destination
  count — so a straight legal crossing peaks at the midpoint). All gates
  (`mayEnter`, containment sweep, seaworthiness DoT) read data, so nothing
  else changed server-side. **Teleport menu untouched** — it stays as fast
  travel per the standing S3 decision; the boat is the intended way across.
- **Sailing compass** (`BoatController`, no ORDER change — built inside the
  existing controller): while at the helm, a slim FPS-style strip along the
  top of the screen shows a marker per island — name over a coloured tick,
  shoreline distance under it ("3.2k") — sliding as the boat turns
  (±110° window, dead-ahead centre tick). Shows only PLACED islands
  (checks `Workspace/World` for the mesh, so un-imported islands stay off
  it) and veils the Maelstrom until all six hearts, mirroring the travel
  menu. Rebuilt on every `showCompass()` (helm entry); hidden on foot.
  Knobs: `COMPASS_*` + `COMPASS_COLOR` at the top of the controller.
- **Docs amended in place**: `docs/revamp-plan.md`'s island table +
  "islands in a line" bullets now carry the arc positions.
- **Unreviewed in Studio.** Likely tuning asks: leg lengths / travel-time
  feel, boat top speeds, compass size/placement, whether locked islands
  should show on the compass at all, marker colours.

### The swamp restart (2026-08-27, step 1 in the tree)

User verdict on the shipped mangrove fen: "absolutely atrocious" — grey
unpainted objects in the canopy, water floating above the terrain, prop
collision walling off the walkable ground. Their chosen fix: **delete the
whole model and rebuild step by step, one reviewed step per prompt.**
Everything in this section supersedes the older fen notes (the "authored
water network", canopy roof, marsh growth, prop scatter — all deleted;
recover from git before 7165cf4 if a step wants to crib).

- **Step 1 (7165cf4)**: the bare landform — ONE object `Swamp_Base` off
  the shared `build_island_base`, grey on purpose, radius 180, +Z shore at
  rel Z=158, spawn re-keyed to rel Z=128. A height experiment (22-stud
  dome, dd1ec0a) was reverted flat on review (4e00735): the marsh needs a
  level floor.
- **Step 2 (c171f12)**: the fen palette back on the three base bands
  (M_Peat / M_Mud / M_WetMud, mirrored in `WorldService.MESH_COLOR`).
- **Step 3 (current): the marsh — one huge flooded interior.** A first
  cut of 9 discrete circular pools was rejected in the same review
  ("more random, not just circles... a huge pool that the trees can live
  in like a mangrove forest") and replaced by a NOISE-FIELD marsh:
  `_swamp_field` (3 octaves) decides flooded-floor vs ground per point;
  `_swamp_height` sinks the whole interior floor BELOW the water plane
  (bed ~0.9 vs water 2.2 — deliberately wadeable) and lifts islets/
  peninsulas out of it, with the boss MERE (rel X=0 Z=74 r=30, Old
  Gnashroot's arena) forced open + a dry spawn shelf; the interior faces
  at/under the waterline paint wet mud. `build_swamp_water` emits ONE
  ragged sheet out to u≈0.68, where the PROFILE's rim band has already
  climbed above water level — so the sheet's edge is buried in rising
  ground on every bearing and the islets simply poke through it.
  **Binding rule (a first cut reproduced the shipped bug, caught on
  render): water may only ever emerge FROM ground — never end a sheet
  over its own bed.** Swamp casting is back ON (`Swamp_Water`,
  waters="swamp", ocean-dress via `Ocean.INTERIOR_WATER_NAMES`).
  LAVA_PONDS (cleared first — the volcano's linger otherwise) records
  ONLY the mere: the rest of the marsh is exactly where the tree step
  wants to plant, so it stays off the keep-clear list. Knobs:
  SWAMP_WATER_Z 2.2 / BED_Z 0.9 / ISLET_Z 3.5 / MARSH_U 0.60 / RIM_U 0.70.
- **Prop entries**: `WorldService.MESH_COLOR` still carries only the base
  bands (+`Swamp_Water` rides the interior-water dress, no entry needed);
  every future prop object must get its entry back when its step lands or
  it renders importer-grey.
- **THE LEAK, pinned (real bug this restart exposed)**: `configure()`
  never resets globals between pack islands, and the shipped
  ice/gloom/wreck meshes were built with the VOLCANO's
  `PEAK_JAG`/`PEAK_TERMS`/`CRAG_CALM` still live (the old swamp passed
  them through untouched). Those values are now pinned EXPLICITLY on the
  ice overrides so the three approved islands stay byte-identical
  (verified: gloom mesh bottom -16.53 / gate crest 19.12061 match a HEAD
  pack build; they drift to -15.28/18.96 without the pin). Any future
  island inserted into ISLAND_ORDER must set every shape key it cares
  about — assume the previous island's globals are still loaded.
- **Next steps (each its own prompt, wait for the ask)**: presumably
  materials/palette, then water, then landforms/props, then the dock,
  then the boss arena re-key. Don't build ahead.

### The volcano restart (2026-08-27, step 1 in the tree, import owed)

User: "completely start from scratch... make a big base island with nothing
on it. erase the volcano island blender model and start from 0." The swamp
playbook applied to Ashfall Caldera — reviewed from PNG previews
(`island_volcano_preview.png` + `_apron`/`_approach`) before landing.

- **Deleted from `island_gen.py`**: the whole stratovolcano build (~700
  lines) — switchback trail + TRAIL_* globals, terraces, lava
  (`_lava_flow`/`build_lava`/`_lava_theta`/`_pond_fits`/FALL_*/LAVA_LEVEL/
  LAKE_U), rock/prop scatters, the shore dock, `print_volcano_handoff`.
  KEPT because shared: `LAVA_PONDS` (now documented as the cross-island
  pool keep-clear registry — its name is a relic), `_clear_of_ponds`,
  `_jagged_disc`, `_pool_disc`, `_interior_spot`, `_near_dock_corridor`,
  `add_ribbon_slab`.
- **Step 1 (`build_volcano`)**: ONE `Volcano_Base` object off the shared
  base machinery. Shape went FOUR rounds against previews: 158-peak dome
  (read as a hill) → 205 concave cone (user: "too uniform... really really
  really tall... jagged... more randomized") → **~895-stud shattered
  spire** (broken ridgeline to ~950 via PEAK_JAG 28, near-vertical craggy
  flanks CRAG 68/FREQ 0.016, SEGMENTS 96) with a summit crater dish and
  the broad flat ash apron (u 0.70-1.0; RIM_FLAT keeps it level), standard
  tide-band shore. ~1,630 tris.
- **NEW GENERATOR KNOB `CRAG_RADIAL_FREQS` (angular, height)** — the radial
  outline wobble's noise frequencies, default (6.0, 4.0) = the old
  hardcoded pair. The volcano cranks them to (13, 18) so the silhouette
  wanders DIFFERENTLY at every height (spurs/gullies/ledges, not vertical
  fluting — the round-3 finding: with u varying only 4 noise units over
  900 studs, cliffs read as columns). **Unlike the legacy shape keys this
  one RESETS in configure()** when not overridden — the first pack build
  leaked the volcano's pair into gloom/wreck (which use the wobble without
  setting frequencies; bottoms drifted -16.53→-16.86 / -18.25→-18.22,
  caught by the HANDOFF check). Prefer this reset-in-configure pattern for
  any FUTURE new shape global; the legacy keys keep the pin-every-entry
  rule.
- **THE SEED LEAK (hard-won, a6's catch)**: `SEED` is a global default (7)
  that only the maelstrom entry overrides — swamp/ice/gloom/wreck INHERIT
  whatever the volcano leaves in it, and a draft that set `"SEED": 11`
  reshuffled every downstream island's random scatter (wreck's keels
  drifted -18.25 → -18.93). The volcano entry now pins `"SEED": 7` with a
  warning comment; a pack build verified all reference bottoms
  (ice -9.00 / gloom -16.53 / wreck -18.25 / maelstrom -11.95). **Rule: a
  mid-order island must never change SEED without first pinning it on
  every entry after it.**
- **Luau side**: Islands.volcano — `meshBottom` REMOVED (bare landform
  bottoms at the -9 skirt), spawn re-keyed to rel Z=511 (pack HANDOFF),
  restart comments; MESH_COLOR collapsed to the three `Volcano_Base` bands
  (prop/lava/dock/foam entries deleted — return with their steps;
  `Volcano_Lava`'s Neon override removed with them); `Volcano_Lava` STAYS
  in World.FISHABLE_NAMES/WATERS_BY_PART + NON_COLLIDE for its return —
  the `waters = "volcano"` roster and Phoenix chase are dormant meanwhile.
  LavaController scans by name and finds nothing (absence-safe by design);
  EruptionService still runs (its bombs are Hazards events, no lava parts
  needed). Pyrelisk's arena keys off the DELETED dock — left as an interim
  open-water arena with a re-key note (the Gnashroot precedent).
- **Pack regenerated in the same commit** (the a6 rule: whoever lands an
  island change regens the pack after checking peers' uncommitted hunks).
  Stale old-design previews (`_dock`/`_tower`) deleted.
- **Step 2 — THE LAVA (same day; user: "realistic... no gaps... all the
  way from the top to the floor and ocean... a good amount")**: one
  `Volcano_Lava` object (contract name, never split): a crater lake (r48
  at 842) + SIX rivers pouring through NOTCHES carved in the rim (the
  entry's NOTCHES mirror the new `LAVA_FLOWS` table BY HAND — keep them in
  step or a river runs over an uncut rim), each river ONE continuous
  `add_strip_slab` ribbon (shared vertices = gap-proof by construction)
  that hugs the real crag via BVH raycasts, runs the full 900-stud flank,
  crosses the apron and fans into a molten sea delta at the waterline.
  Mid-apron pools + deltas recorded in LAVA_PONDS (12 fishable ponds).
  The 270° spawn/dock wedge stays lava-free. **Rivers are DRAPED SHEETS,
  not two-edge strips** (user round: "the lava is blending into the rock…
  goes behind the rock… make it right above, resting on it, not
  separated"): a 168×7 grid (`_lava_sheet`) where EVERY vertex raycasts
  its own ground and rides above it — a strip's interpolated middle let
  crag facets poke through; the grid conforms to every facet, coats
  spurs, sinks into gullies, and its 10-stud underside/edge walls stay
  inside the rock so nothing ever separates. Rules stacked over three
  "blending into the rock" rounds: row spacing ~3.5 studs (on a 70° wall
  a 7-stud row is ~20 studs of drop and facets clip through mid-cell);
  **the lift is SLOPE-SCALED** (+0.5×the local drop per row, capped +12:
  a vertical offset of L on a wall of slope θ is only L·cosθ of true
  clearance — ~¼ of L on these cliffs); and **`LAVA_LIFT` = 3.6** (user:
  "a thicker sheet… its own object layered on top") so ~3.6 studs of
  molten side wall stand proud of the rock everywhere — the exposed edge
  is what sells the lava as a distinct slab resting on the mountain. Widths 7→27+ studs, bulging
  mid-flank, ×1.35 on the main breach (48°).
  `waters = "volcano"` + Phoenix chase are LIVE again; Volcano_Lava back
  in MESH_COLOR + Neon. LavaController dresses it automatically (bubbles,
  scrolling crust) — it scans `*Lava` by name.
- **Next steps (each its own prompt, wait for the ask)**: props/scatter,
  the dock (+ Pyrelisk re-key), foam, eruption tie-in. Don't build ahead.

### The boss redesign: unique movesets, gimmicks, models (2026-08-27, unreviewed)

User: the bosses "all have the exact same moveset... mediocre designs and
gimmicks... redesign all of the bosses except the first one" + rebuild the
Blender models. Landed as e84f7e9 (engine + data + client) and ba93efb
(art). **Brinejaw is untouched** and still runs the original name-is-handler
book; **`creatures.glb` re-import owed** (until then the new FIGHTS run on
the old meshes — movesets are code-side and live).

- **The boss arsenal** (`CreatureService`, section "the boss arsenal"): the
  per-island movesets are built from new parameterized primitives in
  `BOSS_ATTACKS` — `charge` (line rush; optional `leap`, `slamRadius`,
  hazard `trail`), `beam` (swept jet, ticks WITHOUT i-frame bypass, optional
  `chill`), `poolvolley` (globs leaving pools), `barrage` (telegraphed
  strikes: patterns `scatter` / `everyone` / `line`+`fan` / `wall` /
  `rings` — rings are annulus novas with their own damage rule), `snaretrap`,
  `decoys` (proximity mines, optional `drift` — the server mirrors drifting
  positions to clients via low-cadence `decoyMove`), `phantom` (buried
  teleport-to-flank ambush), `undertow` (long pull + raining globs),
  `anchortoss` (spine-visual throw whose strike fires a `chain`). A
  Bosses.luau attack names its engine behaviour with **`p.handler`** (no
  handler field ⇒ the attack NAME is the handler — Brinejaw's rule),
  borrows a stock telegraph with **`p.tell`**, and colors client effects
  with **`p.skin`**. `dive` gained `p.shatter` (pool at the burst);
  `pickBossAttack`'s empty-pool fallback returns the phase's FIRST attack
  (the hardcoded "snap" would nil-crash books that renamed their bite).
- **Three timed systems on the creature struct**, ticked in `update()`
  beside globs/puffs so they run mid-attack and die with the boss:
  `pools` (lingering ground hazards: damage tick and/or a broadcast
  `chill`), `strikes` (tell at `tellAt`, hit at `hitAt`; disc or annulus;
  optional snare/chain/pool/hitEvent riders), `lures` (decoys/kegs:
  detonate on proximity, fizzle on expiry).
- **The kits** (each boss's gimmick is one-of-a-kind): **Old Gnashroot** —
  the fen grabs you: `snaretrap` roots players in place, `deathroll` charge
  leaves slowing sludge, `bogspit` pools, `rootwave` marching line.
  **Rimefang** — the cold: `frostbreath` beam + frost-slick trails/shatters
  all apply chill SLOW; `breach` airborne charge, `bergfall`, `shardnova`
  rings, `undersheet` dive weighted double. **Pyrelisk** — heat: `lavawake`
  charge trail, `magmajet` beam, `slagspit`, `ventstorm` (bomb on EVERY
  player), `cinderring` novas — standable ground burns away. **Noctyss** —
  light: `falselight` detonating decoy lures, `inkveil` (client blind via
  `inkBlast`), `phantom` lights-out ambush, `lurepull`→`needlefangs`.
  **Admiral Wrack** — naval: `broadside` ranked walls, `anchortoss` CHAINS
  the target to the spot (client leash), `powderkeg` drifting mines,
  `keelrush` ram, `boarding` brood (his identity; the only boss brood
  kept). **Kraken** — the storm: `tentaclelash` (strike under EVERY
  player), `stormcall`, `wreckhurl`, `inknova`, `undertow` (the maelstrom
  weaponized); the tentacle-ring exposure gimmick is unchanged.
- **Client** (`CreatureEventController`): `SKIN` palette (peat/root/frost/
  lava/ink/lure/ember/wreck/storm); new moments `poolSpawn`, `strikeHit`,
  `inkBlast`, `chill`, `snare`, `chain`, `decoy`/`decoyMove`/`decoyPop`,
  `beam`, `phantomOut`/`phantomIn`; telegraph kinds `mark` (point ring) +
  `ringTell` (annulus band). **Movement effects follow the pull's
  client-applied pattern**: each client roots/slows/leashes its OWN
  character if inside the broadcast radius; one walkspeed effect at a time
  (harshest mult holds while overlapping, captured base restored exactly,
  everything cleared on respawn). The chain clamps the root's CFrame to
  the leash circle per Heartbeat.
- **Art** (`creatures_gen.py`, two-lane fleet with per-model render review;
  bboxes all within ±20% of baseline so rows/hitRadius hold): Gnashroot
  gator-oak (fungal shelf canopy, glowing snare-root Marks), Rimefang
  16-segment ice-slab serpent (crystal crown, frost-crack glow), Pyrelisk
  obsidian plates over a literal molten `_Marks` core chain, Noctyss
  angler queen (mostly maw; caged glowing lure bulb is the focal point),
  Admiral Wrack fused into his flagship's bow (real fouled anchor + chain,
  glowing gunports), Kraken storm-crag mantle with spiral biolum bands +
  matching rebuilt tentacle. Pack build green: 68 species, 32,427 polys.
- **Unreviewed in Studio.** Likely tuning asks: every new number (arm
  windows, pool durations, chill mult, chain leash, undertow strength),
  decoy readability vs the real lure, whether snare needs a jump lock,
  ringTell clarity, and the usual arena-fit pass per island.

### First person, arms, and the viewmodels

- **First person is enforced at two levels:** `default.project.json` sets
  `StarterPlayer` `CameraMode = LockFirstPerson` and zoom 0.5/0.5 (engine
  level, project-file change ⇒ restart `rojo serve`), and `CameraController`
  re-asserts the lock every render step and on `CharacterAdded`. Menus call
  `CameraController.setCursorFree(true/false)`; a modal's backdrop button is
  `Modal = true` so the engine releases the mouse lock.
- Roblox hides the local character in first person, so what you hold is a
  **client-only rig parented to the Camera**. Shared machinery lives in
  `src/Client/Modules/Viewmodel.luau`: sway, walking bob (driven by
  `Humanoid.MoveDirection`), idle breathing, the per-frame pin (memoised so
  two rigs alive during a swap don't double-step the bob), `Rig`
  (parts with camera-space offsets in named groups; `Rig:pin(pin, extras)`
  applies a per-group transform), clip loading/sampling, `buildArm`,
  `placeArm`, and `watchArms`. **Tune bob/sway there.**
- **The arms are classic block Roblox limbs** — box lower arm (1×1.2×1) +
  box hand (1×0.3×1), `Viewmodel.HAND_SIZE` / `LOWER_ARM_SIZE` — by user
  decision after their bundle avatar's sculpted hands looked wrong. Coloured
  from the avatar's `BodyColors` (so still the player's skin). Builds are
  gated on `Player:HasAppearanceLoaded()` (`watchArms`, 10 s timeout) because
  `BodyColors` isn't real until then. **Shirt sleeves are not painted on**
  (would need per-face `Texture` crops of the shirt template) — ask before
  doing that. Other players see the server-welded rod on the real character;
  they see **no** cast swing and **no** punches — that would need Motor6D /
  Roblox Animation work on the real rig, a different architecture; ask first.
- **Rod viewmodel** (`RodViewmodelController`): the rod rebuilt from its data
  row (server stamps `RodId` on the welded `EquippedRod`; never clone the
  welded copy — it's already in the hanging-hand pose) plus the right block
  arm. Shows exactly while `EquippedRod` exists in the character. Pose knobs
  at the top (`GRIP_POSITION (1.45,-1.6,-2.6)`, `ROD_PITCH` 58°, `ROD_YAW`
  3°, `FOREARM_DIRECTION`). Tracks the tip (`getTipPosition()`, from the
  row's `model.length`) for the fishing line. The rod mesh carries a static
  idle line + red/white bobber (`Rod_Line`, `Rod_BobberTop/Bottom`) that
  `setTackleVisible(false)` hides during a cast.
- **Cast animation:** `assets/rod_cast_anim.py` → generated
  `Shared/Data/RodCastAnim.luau` (camera-space CFrame per frame, 30 fps,
  `RELEASE_TIME` 0.3 s) + `rod_cast.blend` preview. Played by
  `playCast()` / `releaseCast()` as a transform about the elbow via
  `Rig:pin`; the last frame is **held** (rod lowered) while the line is out,
  then eased back over `CAST_RELEASE_BLEND`. Not a Roblox Animation asset on
  purpose (code-posed rig, no upload step). Edit `KEYS` and re-run.
- **Fists viewmodel** (`FistsViewmodelController`): both block arms in a
  guard (`FIST_POSITION (0.8,-1.1,-2.4)`, `FOREARM_DIRECTION`, `HAND_ROLL`;
  left is the mirror), shown while the `Equipped` attribute reads
  `"weapon"` **and** `EquippedWeaponId` is `"fists"` (a crafted weapon is
  the weapon viewmodel's, below).
  **Punches:** `assets/fist_punch_anim.py` → `Shared/Data/FistPunchAnim.luau`
  — clips `jab`/`cross` (cross = jab mirrored at export), a track per fist,
  0.23 s, `HIT_TIME` 0.09. `punch()` cycles `SEQUENCE`, blends an
  interrupted punch over `PUNCH_BLEND`, returns the hit time. **How the
  arm moves is the part that took four reviews:** the fists bypass
  `Rig:pin`; `Viewmodel.placeArm` keeps the **elbow fixed** (off-screen) and
  **re-stretches the forearm** to wherever the clip's translation puts the
  fist, so a punch extends the arm toward screen centre. Every earlier
  version moved the rigid arm forward and dragged the forearm's cut-off
  elbow end into view — that square face was the "back of the hand" the user
  kept seeing. Track rotation is ignored entirely now; keep it that way
  unless the user asks for a specific tilt. A `Trail` off the leading fist's
  knuckles streaks during a punch.
- **Weapon viewmodel** (`WeaponViewmodelController`, 2026-08-22,
  **unreviewed**): a crafted weapon built fresh from its `Weapons` row by
  `Shared/Modules/WeaponModel` (WeaponPack mesh variant, or procedural
  club/blade parts as fallback) plus the right block
  arm, **the rod's architecture, not the fists'** — one rig group, the
  swing clip applied about the elbow through `Rig:pin` exactly like the
  cast. Shows while `Equipped` is `"weapon"` and `EquippedWeaponId` names a
  row with a `model`. Pose knobs at the top (`GRIP_POSITION
  (1.55,-1.65,-2.55)`, `WEAPON_PITCH` 70°, `WEAPON_YAW` 6°, **`WEAPON_ROLL`
  −90°**, same `FOREARM_DIRECTION` as the rod). **The roll matters:** the
  mesh blades are thin along the axis that lands on camera Z after import,
  so without it you see the flat of the blade ("held horizontally", user
  2026-08-22); −90° puts the edge forward. `WeaponModel.HOLD_OFFSET` (the
  welded world copy) carries the same roll — keep them in step. If an edge
  ever faces the player, flip the sign (the importer's axis flip is
  inferred, not measured). **Swings:** `assets/weapon_swing_anim.py`
  → `Shared/Data/WeaponSwingAnim.luau` + `weapon_swing.blend` — clips keyed
  by the row's `swing` name: `chop` (club, 0.45 s, `HIT_TIME` 0.18) and
  `slash` (blade, 0.24 s, `HIT_TIME` 0.10); both ends of a clip are the
  identity, an interrupted swing blends over `SWING_BLEND`, `COMBO_WINDOW`
  gates chaining. `swing(name)` returns the hit time. A `Trail` along the
  weapon's length (grip → tip, both attachments on `Weapon_Grip`) runs
  while a clip plays. Edit `CLIPS` in the script and re-run.
- **Hotkeys must use `ContextActionService:BindActionAtPriority` at
  `ContextActionPriority.High`**, sunk, never `InputBegan` + `gameProcessed`
  (Roblox's camera scripts bind keys through CAS and mark them processed).
  Keys in use: `1` rod, `2` weapon, `C` crafting, `I`/`B` inventory,
  right-click cast, Space/left-click/tap reel click (bound only during a
  cast), left-click/tap attack (bound only while a weapon is out). **Menu buttons
  (user request, 2026-08-22, amending the earlier "no HUD buttons"):**
  `MenuButtonsController` draws a bottom-left row — **BAG (I) / CRAFT (C)
  / ADMIN (P, admins only)** — each toggling its menu through that
  controller's exported `setOpen()` / `isOpen()` and closing the other two
  first; the lit button follows the real open state. First person locks
  the mouse, so **holding ALT frees the cursor** (bound LeftAlt/RightAlt at
  High priority; "hold ALT to click" hint on keyboard devices); menus free
  it themselves while open, so switching by button needs no ALT. Touch just
  taps (this is what let touch open menus at all). Still **no prompts**
  (the cast prompt stays removed), and **touch still cannot cast or swap**.

### Inventory and equipment

- `InventoryService` (server, in-memory): every player gets `twig_rod` and
  `fists` on join; `GetInventory` / `InventoryUpdated` remotes carry **one
  mixed list of rod AND weapon ids** (the service doesn't care what an id
  points at; `grantItem` checks it exists in `Rods.items` or
  `Weapons.items`, and each client tab keeps the ids its own table knows).
  Rod rows in `Shared/Data/Rods.luau` carry three stats centred on 1.0
  (`luck`, `power`, `control`), the held-mesh info (`model`, `grip`,
  `length` — both must match `rod_gen.py`), and the `reel` block (clicks,
  bar speed, zone widths). Weapon rows are under Combat, below.
- **Loadout** (`Shared/Config/Equipment`: `"rod"` | `"weapon"`) is owned by
  the server: `InventoryService.setEquipped` validates and publishes the
  **replicated `Equipped` attribute on the Player**; `onEquipChanged(fn)`
  fans out (each callback in its own thread) to `RodService` /
  `WeaponService` (weld/remove the world rod / weapon) and `FishingService`
  (abandon a cast in flight). `RequestEquip` is the remote; `EquipController`
  sends it on `1`/`2`. **"Weapon" covers bare fists** — the fists are the
  starter row in `Weapons.luau`, so `2` is always "whatever weapon I've
  picked" (`EquippedWeaponId`, `Equipment.WEAPON_ATTRIBUTE`) the way `1` is
  "whatever rod I've picked" (`EquippedRodId`). `Equipment.FISTS` no longer
  exists (renamed 2026-08-22 with the weapons slice).
- The inventory menu is a centred modal, `I` or `B`, with **three tabs —
  Rods | Materials | Weapons** (user request, 2026-08-22): a card grid for
  the open tab and a detail panel whose stat rows relabel per kind (rod:
  luck/power/control; weapon: damage, swings/sec, reach; material: none,
  count in the title). Rods and weapons both come from the mixed owned list
  (`GetInventory`/`InventoryUpdated`; weapons shown in `Weapons.order`),
  materials from `GetMaterials`/`MaterialsUpdated`. The card in the hand
  gets an accent **E** badge and "(equipped)" in the detail — read from the
  `Equipped` + `EquippedRodId` + `EquippedWeaponId` Player attributes — and
  the grid re-renders on open and when those change. **Menu pass
  (2026-08-22, unreviewed):** every tab uses the one `fillIconCard` layout —
  icon slot, name, rarity strip along the top, an **`x12` count badge**
  (materials), and a **small blue dot top-left** on the thing in hand
  (replaced the "E" badge). Materials **no longer show a colour dot**: the
  user is making icons, so each `Materials` row carries `icon` (asset id,
  `""` = blank slot) and `rarity` (driftwood/kelp Common, scale Uncommon,
  pearl + chitin Rare, cursed bone Epic); `color` stays for recipe rows and
  the reward pop only. The detail panel has an **Equip / Equipped button**
  for rods and weapons (`requestEquip`: picks it via
  `RequestEquipRod/Weapon` then raises that kind via `RequestEquip` — the
  crafting menu's Equip does the same now). Rod/weapon `icon` fields don't
  exist yet (nil → blank slot). Layout knobs at the top of
  `InventoryController`.
- **Rarity is shown on rods and weapons** (2026-08-22): every rod/weapon row
  carries `rarity` (Common/Uncommon/Rare/Epic/Legendary) and rods may carry a
  `perk` (the Abyssal's "Abyssal Pull", a `minRarity` floor honoured in
  `FishingService.rollCreature`). The one palette lives in
  `Shared/Modules/Rarity.luau` (`COLOR`/`ORDER`/`colorOf`/`indexOf`) — use it,
  don't add a fourth rarity-colour table. In both the inventory and crafting
  menus each rod/weapon card gets a thin rarity-coloured strip along its top
  edge (a separate Frame — kept off the selection UIStroke and off Crafting's
  refreshSlots-owned Tag), and the detail panel tints the item name by rarity
  with a rarity-word caption under it; the Abyssal's perk name+description
  shows under the stats in the **inventory** detail (crafting's detail is too
  tight above the craft button). `FishingController` still has its own local
  catch-pop palette; fold it into `Rarity` if you touch it.

### Fishing

- **Cast gating (user request): you can only cast at water you're looking
  at, within reach.** `Shared/Modules/CastAim.luau` is shared by both sides:
  `aim()` raycasts from the camera against `Workspace.World` only and
  accepts a hit on the part named `World.OCEAN_NAME` within
  `Tuning.Cast.MAX_DISTANCE` (45) of the character; the server re-checks
  (`CLAIM_SLACK`) and **rejects** rather than substituting a point, so the
  bobber lands exactly where the player looked. Client shows "Aim at the
  water." / "Get closer to the water." and doesn't swing on a failed aim.
  There is deliberately no fixed fishing spot (`World.CAST_POSITION` is
  gone). Casting from under palm fronds fails (the ray stops on leaves).
- **Flow** (`FishingController` ↔ `FishingService`): right-click →
  `playCast()` immediately (client predicts) + `RequestCast(landing)`;
  `pendingCast` blocks double-requests and times out (`PENDING_TIMEOUT`).
  On `CastAccepted` the client waits out the clip's `RELEASE_TIME`, the
  bobber **arcs** from the rod tip to the landing point (`ARC_*`), and the
  reel bar + click binding appear when it lands. Rejection eases the rod
  back.
- **Reel:** the server owns a seed; `ReelMath`/`Rng` (lifted from the
  pre-reset backup) replay the identical zone layout on both sides so a
  click flashes instantly and the server still grades it. One **bullseye
  target per round — green ring around a red centre** (user: "too easy" with
  two separate zones), misses shrink zones. Click times are bounded on both
  sides (`CLICK_TIME_TOLERANCE`). The bar (`UI/ReelBar.luau`) is a 340×18 px
  pill: grey track, zones, white marker, nothing else — no text, no button
  (user removed them). Rod `power` scales bar speed, `control` scales zone
  widths.
- **Minigame framework (2026-08-22, Slice 1 of "multiple minigames"; more
  coming — see the plan file `okay-do-you-think-encapsulated-wombat.md`).**
  The reel is now one minigame behind a registry, not hardcoded. **Selection
  is RARITY-GATED (user, 2026-08-22), not random:** `Minigames.pickForRarity`
  (`Shared/Modules/Minigames`) picks from `Minigames.byRarity` — Common/
  Uncommon → `reel`, Rare/Epic/Legendary → `burst` or `snap` (tie broken from
  the seed). This is why the creature is rolled at **cast time** now (see
  Resolution). `Minigames.FORCE = "<kind>"` forces one for testing. The chosen
  kind stamps `config.kind` onto the CastAccepted `config` (rides it verbatim,
  **no new remote**); both sides dispatch via
  `Minigames.get(kind)`. Each minigame = a shared math/authority module
  (`Shared/Modules/Minigames/<kind>`: `configFor`/`begin`/`onEvent`/`perf`/
  `luckFor`) + a client view+input module (`Client/Minigames/<kind>`:
  `onAccepted`/`update`/`onResult`/`endCast`, given a `ctx` of
  cast/gui/submit/bobberPosition). Every minigame reduces to `perf ∈ [0,1]` →
  `Shared/Modules/Grades.luau` (`gradeFor`/`luckFor`, thresholds read from
  `Tuning.Reel`). `SubmitReelClick`→server `onSubmit` is the generic timed-
  input event (optional 4th `extra` arg for e.g. a QTE key); per-cast state
  lives on `cast.mg`. **Slice 1 is zero-behavior-change** — `enabled =
  {"reel"}`, so every cast still rolls the reel and plays identically; the
  reel keeps its raw-score `luckFor`. Reel's own `configFor` (was
  `reelConfigFor`) now lives in `Minigames/reel`.
  - **Slice 2 (multi-lane rhythm) was built then removed** — the user found
    it "too similar to the reel" (it was the reel stacked). All its files and
    `Tuning.Minigames.Lanes` are deleted; don't re-add it.
  - **Slice 3 (2026-08-22): rapid-tap burst live.** `enabled = {"reel",
    "burst"}`, so ~half of casts now roll `burst` — a genuinely different
    input (no sweeping marker): mash to fill a bar before a timer.
    `Shared/Modules/Minigames/burst` (server counts taps) +
    `Client/Minigames/burst` + pure view `Client/UI/TapMeter` (big MASH!
    target, fill bar, draining timer). The window opens on the FIRST tap and
    lasts `Tuning.Minigames.Burst.DURATION` (3s); a tap counts only in-window
    and no faster than `MAX_TAPS_PER_SEC` (human-rate cap); `perf =
    taps/TARGET_TAPS`. **No per-tap echo** (taps are chatty) — the client
    predicts its own fill (with the SAME rate cap as the server, so a full
    bar matches the server count), the server count only decides the grade.
    Resolves via the `FINISH` sentinel (round 0) when **the bar fills** (taps
    reach `TARGET_TAPS`) OR the timer runs out — user, 2026-08-22 — whichever
    first (`OPEN_TIMEOUT` auto-finishes if they never tap); the 30s cast sweep
    is the backstop. **Unreviewed in Studio.** (This is the first proof
    the framework carries a non-reel input with no Fishing*/Remotes edits —
    just new files + the `enabled` flip + a Tuning section.) Burst difficulty
    bumped `TARGET_TAPS` 16 → 20 (user: "slightly harder").
  - **Slice 4 (fish-fight QTE) was built then removed** — the user found it
    didn't work for them and wanted a mobile-first minigame instead. All its
    files (`qte`, `QtePrompts`) and `Tuning.Minigames.Qte` are deleted;
    replaced by "snap" below. (It did leave one lasting lesson: never tween a
    view label's own `TextTransparency` for a flash if the element is reused
    the next prompt — a still-running fade re-hides the new content; use a
    separate overlay. See the burst/snap flash overlays.)
  - **Slice 4b (2026-08-22): tap-targets ("snap") — whack-a-mole.**
    **Mobile-first.** One big circular target appears at a seed-random spot
    (`positionFor`) and vanishes after `Tuning.Minigames.Snap.LIFETIME`
    (1.5s) — the view (`Client/UI/SnapTargets`) is a fixed-size black outer
    ring with a blue inner disc that shrinks as the timer runs — and you
    tap/click it before it's gone; `COUNT` (5) targets in a row;
    `perf = hits/COUNT`. A prompt ("TAP THE TARGETS!") sits up top, hit/miss
    is a separate pop (not on the target, which moves on immediately).
    `Shared/Modules/Minigames/snap` + `Client/Minigames/snap` + pure view
    `Client/UI/SnapTargets`. `extra` = 1 (caught in time) / 0 (timeout); one
    target per round so there's no wrong button — hit/miss is the client's
    honest call, server counts. **Desktop:** first-person mouse-locked, so
    `snap.onAccepted` calls `CameraController.setCursorFree(true)` for the
    duration (re-locked in `endCast`) so clicks land; touch taps regardless.
    Known edge: opening the inventory mid-snap and closing it would re-lock
    the cursor (both call `setCursorFree`); unusual, unhandled. (Earlier
    "5 static buttons, one lit per round" version was replaced by this per
    user request.) **Freeze bugfix (user report, twice):** the view stored
    the hit/miss effect Frame as `self.pop` while the method was also named
    `pop` — the field shadows the metatable method (Lua `__index` only fires
    on missing keys), so `view:pop(...)` tried to CALL a Frame and errored
    right after the round's `answered` flag was set, jamming the minigame
    (disc frozen mid-shrink, clicks dead). Field renamed `popFx`. **Lesson
    for every OO view module: never give an instance field the same name as
    a method.** The earlier stale-sync theory was wrong; this was the real
    cause both times. **Unreviewed since the fix.**
- **Species roll moved to CAST time (2026-08-22)** so the minigame can be
  chosen by rarity. `onRequestCast` calls `rollCreature(rodData)`
  (`Tuning.Rarity.WEIGHTS` × **rod luck only** now — no reel-score bonus,
  since no minigame has happened yet; tiers with no rows skipped; the perk
  `minRarity` floor still applied), picks the minigame from that rarity, and
  stores the creature on the cast. **Design consequence:** the minigame no
  longer influences WHAT you catch (rarity), only the grade (fight/reward).
  `resolveCast` then spawns `cast.creature` via `CreatureService.spawn(row,
  landing, playerRoot, grade)`, grants the basic materials
  (`MaterialService.grantCast`), and sends `CastResolved` (grade, creature). The banner shows only **"Name (Rarity)"** coloured by rarity
  (user, 2026-08-22: the grade — Hooked/Neutral/Enraged — and the score are
  deliberately NOT shown; the grade still silently scales the fish's
  `healthMult`/`rewardMult` in `CreatureService.spawn`). **Walking away
  CANCELS the cast (user, 2026-08-22 — reversed the original "a cast never
  fails" rule):** putting the rod away / swapping rods (`onEquipChanged`),
  losing the character (`AbandonCast`), or idling past
  `Tuning.Reel.MAX_REEL_DURATION` all hit `FishingService.cancelCast` —
  **no creature, no materials** — which fires `CastResolved` with
  `{ cancelled = true, reason = "abandoned" | "timeout" }` so the client's one
  `endCast` path still tears everything down (bobber, line, minigame view,
  cursor re-lock) and shows a dim "Cast cancelled." banner (one message for
  every reason, per the user).
  A minigame played to the end still always lands its catch.
- VFX/SFX hooks: rod-tip trail during the swing, splash + ripple loop at the
  bobber, tug splash on a reel hit, rarity-coloured sparkle on resolve;
  cues `castSwing`, `bobberPlop`, `tug`, `reelMiss`. **Cut by the user:** the
  catch fanfare (`victory.wav`) and the reel-hit pings — don't bring back.

### Creatures

- **Rows** in `Shared/Data/Creatures.luau`, all real fish (user direction):
  Perch, Mackerel, Trout (Common); Bass, Cod, Catfish, **Pufferfish**
  (Uncommon); Salmon (Rare); Tuna (Epic). Each has `rarity`, `archetype`,
  `health` (Neutral-grade HP; `Tuning.Grade[grade].healthMult` scales it),
  optional `rewards`, and a `body` block: `model` (`"FishPack"`), `species`
  (part-name prefix), `scale`, `color` / `finColor` / `markColor`, or
  `shape = "puffer"` for the procedural one. `Creatures.byRarity` is built at
  load. `Tuning.Rarity.WEIGHTS` = Common 70 / Uncommon 30 / Rare 8 / Epic 2.
- **Species pack:** `assets/fish_gen.py` is a parameterised generator —
  each entry in `SPECIES` is body profile, tail kind (`forked` / `rounded` /
  `square` / `lunate`), dorsal/anal fin list (`soft` / `spiny` / `sickle` /
  `adipose`), pectoral, finlets, barbels (`chin` / `whiskers`), `jaw`
  (`kype`), side marks (`stripe` / `bars`) — all built by one code path and
  **exported together into the single `fish.glb`** (objects
  `<Species>_Body/_Fins/_Eyes/_Marks`, spaced along Y for preview) so it is
  still one Studio import, named `FishPack`. Optional second arg renders
  `assets/fish_preview.png`, a coloured side-view line-up — use it to judge a
  design change before importing. Every species is 2 studs long with
  **length > height > width** (required by the flat-lay logic below).
  `CreatureModel.build` clones the species' parts out of the pack and
  **renames them to the generic `Fish_Body/Fins/Eyes/Marks`**, so physics,
  hit feedback and VFX never know which fish it is. A row with no `species`
  clones its template whole; a missing pack/species falls back to a
  ball-and-slab stand-in with a warning.
- **Pufferfish** is now a real low-poly **FishPack species** (2026-08-22,
  user asked for a better-looking, more-low-poly puffer). `build_puffer` in
  `fish_gen.py` (`custom="puffer"` in `SPECIES`) makes a faceted ellipsoid +
  cone spikes + big hex eyes + a beak, exporting the same
  `Puffer_Body/_Fins/_Eyes/_Marks` so `CreatureModel` picks it like any
  other species. The row keeps `shape="puffer"` as a **pre-import parts
  fallback** (`CreatureModel.buildPuffer` — the old spiky ball), so the
  enemy is still visible before the pack is (re)imported; `CreatureModel.build`
  tries the pack species first, falls back to the parts build.
  - **Orientation gotcha (took two tries):** `flatOrientation` stands the
    SHORTEST bbox axis up, so for the puffer to sit belly-down/upright the
    top-to-bottom **height must be the smallest** dimension — the exact
    opposite of the normal fish (which are shortest-in-width so they lie on
    their side). The **spikes reshape the box**: straight up/down pole spikes
    added a full spike-length to the height and flipped width to smallest,
    landing it on its side. Fix: **no pole spikes**, and the generator prints
    the final bbox (`width 1.74 / length 2.35 / height 1.16`, y>x>z) to
    verify ordering without a Studio round-trip. Nose-tail (Y) stays the
    single longest (tail spike along −Y), so the rusher's lunge is unaffected.
  - `PUFFER_HALF = (0.70, 1.0, 0.58)` (width, length, height). Health 150,
    roughly a third of Uncommon catches — random; a force-spawn debug would
    help reliable testing. **Re-import of `fish.glb`/`Assets.rbxm` pending**
    for the mesh to show; until then it's the parts fallback.
- **`CreatureService`** (server): flat array of structs, **one Heartbeat**,
  anchored models moved by `PivotTo`, **no Humanoid** (invariant). No
  pooling yet (deliberate; add with the broader archetype loop).
  - **Orientation is read from the bounding box, not assumed**
    (`flatOrientation`: longest axis = nose–tail, shortest = up). Two
    hard-coded-axis guesses came out wrong in Studio; this is invariant under
    whatever the importer does. Nose–tail must always be the single longest
    axis. Which of the two shorter axes is smallest sets what points up:
    normal fish keep width smallest so they lie on their side
    (length > height > width); a creature meant to stand upright makes
    height smallest instead (the puffer: length > width > height). Spikes /
    fins count toward the box, so check the built bbox, not just the body.
  - **The throw (user decision, a scoped exception to "no physics"):** on
    spawn the model is welded into one assembly, unanchored, launched with a
    solved ballistic velocity + tumble and a `VectorForce` cancelling half of
    gravity, and re-anchored the instant it rests (`hasLanded` → `settle`,
    down-raycast onto dock/sand/ocean, eased into the flat pose). It lands
    `THROW_PAST` studs **past the player on the inland side** (over their
    head from the dock). Physics owns a creature for ≤ ~2 s and never during
    behaviour. Knobs `Tuning.Creature.THROW_*`.
  - **Flop** (rewritten twice; current version approved): the fish lies flat
    on its side and hops with a yaw swish and nose pitch — **no roll, no
    flip**. Knobs `FLOP_*` / `WIGGLE_*`. Replicated attributes `Thrown`,
    `Landed`, `Flops` drive client VFX/SFX. **Made dramatic (user,
    2026-08-22):** `FLOP_HEIGHT` 0.7 → 3.2 with a longer hop (0.5–0.75 s) so
    a landed fish looks like it's throwing itself into the air.
  - **Juggling (user, 2026-08-22):** a hit now also launches a creature
    straight UP (`applyKnockback`'s 4th arg `lift`), and it hangs on an
    airborne track — `updateAirborne`, dispatched **before** the archetype
    branches in `update`, so a juggled creature can't rush/flop until it
    lands. It rises/falls under `JUGGLE_GRAVITY` (62; with `LAUNCH_SPEED` 11
    that's ~1 stud up, ~0.35 s hang — cut from 26/~5.5 studs, which the user
    found way too high), drifts on its existing horizontal knockback damped by
    `JUGGLE_AIR_DAMPING`, and tumbles at `JUGGLE_SPIN`; landing ticks `Flops`
    so the splash/puff fires. A hit while airborne **re-sets** the upward
    velocity (not additive) so combos keep a steady rhythm instead of
    rocketing away. **Horizontal knockback is deliberately unchanged** — the
    user asked for vertical only. **Gotcha found the hard way:**
    `JUGGLE_AIR_DAMPING` started at 2.2 against the ground's
    `KNOCKBACK_DAMPING` 9, which let a hit carry a creature ~4x further while
    airborne — the user read that as "the horizontal knockback got bigger"
    even though `KNOCKBACK_SPEED` never moved. The two are now equal (9);
    keep them equal unless air hits are meant to travel further.
  - **Hostiles resist knockback + move faster (user, 2026-08-22).** Being
    able to punt an attacking creature across the beach made hostiles
    harmless, so `applyKnockback` scales the horizontal shove by
    `C.KNOCKBACK_MULT_BY_ARCHETYPE` (`rusher` 0.25, `shambler` 0.2; anything
    unlisted takes the full push, so passive fish still slide as before).
    Scaled inside `applyKnockback`, not at the call site, so each weapon
    row's own `knockback` stays meaningful. **Vertical launch is scaled the
    same way** by `C.LAUNCH_MULT_BY_ARCHETYPE`, with hostiles at **0** — they
    never leave the ground (user, 2026-08-22: a creature held in the air
    can't attack, so juggling one neutralised it for free, undoing the
    challenge the resist was meant to restore). Juggling stays a thing you do
    to the passive catch. Both tables are plain `{ [archetype] = number }`,
    unlisted = 1.0, and values > 1 are valid (a floaty jelly could take more
    lift). Speeds raised alongside: `RUSH_SPEED` 26 → 38, rest
    0.5–1.1 → 0.3–0.7 s, windup 0.35 → 0.28, turn 220 → 280°/s;
    `SHAMBLE_SPEED` 7 → 12, turn 120 → 170°/s. Lift comes from the weapon row's optional
    `launch`, else `Tuning.Combat.LAUNCH_SPEED` (26); no row sets it yet, so
    a heavy club can be made to juggle harder later without a code change.
  - **Health:** `damage(creature, amount, attacker?)` (kill at 0 → despawn +
    `CreatureService.Killed` BindableEvent `(row, grade, killer)` — consumed
    by `ProgressionService` and `MaterialService`), `applyKnockback(creature,
    dir, speed, lift?)` (decaying horizontal slide that **re-grounds Y every
    frame** via `groundedPos` — an earlier version drove the fish into the
    rising beach — plus the vertical juggle launch above),
    `findByPart`, `inRange(pos, radius)` (nearest-first), `isAlive`.
    Replicated attributes `CreatureId`, `Health`, `MaxHealth`. Parts are
    `CanQuery = false`, so targeting is proximity, not raycast.
  - **`rusher` archetype** (the pufferfish; the only behaviour so far,
    `updateRusher`): idle-flop (still ticks `Flops`, slowly turns to face the
    nearest player) → wind-up telegraph (tuck and face) → lunge along a
    locked direction with a hopping arc (`RUSH_SPEED`, `RUSH_HOPS`) → on
    contact (`CONTACT_RADIUS`) **rams the player** for
    `CONTACT_DAMAGE_MIN..MAX` through `PlayerService.damage` — **never**
    `CreatureService.damage`/`Killed`, which stay creature-death only so
    progression/materials are unaffected — recoils `CONTACT_BOUNCE`, resets.
    Punches still knock it back (shared `slideKnockback`). All CFrame-driven
    from the one Heartbeat. Knobs `Tuning.Creature.RUSH_*` / `CONTACT_*`.
    **Obstacle collision (bugfix 2026-08-22):** both the knockback slide and
    the lunge move `creature.pos` horizontally and used to tunnel the fish
    through rocks/trunks/dock (they only raycast *down* for ground). Now
    `resolveHorizontal` casts a forward ray (`groundParams` has
    `RespectCanCollide = true`, so fronds/bushes/foam don't count) and stops
    the fish `halfThickness` short of any solid part; a shove that hits a
    wall zeroes `knockVel`, a lunge that hits one drops back to flopping.
    Other rows' `archetype` values (`drifter`, `charger`, `spitter`) are
    **not read yet** — those fish just flop. Despawn is now
    fight-aware (user, 2026-08-22): `LINGER` (30 s) counts from
    `lastFoughtAt`, which `CreatureService.damage` resets on every hit, so a
    creature never vanishes mid-fight — only after 30 s of the player not
    attacking it.
  - **Hostile non-fish creatures + the `shambler` archetype (2026-08-22,
    unreviewed).** Three rarer non-fish enemies that roll/spawn through the
    exact same rarity path as fish: **Snapjaw Crab** (Rare, `rusher`, flat),
    **Drowned Deckhand** (Rare, `shambler`, upright), **Drowned Angler** (Epic,
    `shambler`, upright — the zombie fisherman). Two new bits of engine:
    (a) **`shambler`** (`updateShambler`) — stands and trudges straight at the
    nearest player at `SHAMBLE_SPEED`, no windup, ramming on contact (reuses
    `CONTACT_*` + `PlayerService.damage` + `resolveHorizontal`, same as the
    rusher). (b) **upright stance** — `body.stance = "upright"` makes
    `CreatureService.spawn` use `uprightOrientation` (identity + pivot-to-feet
    clearance) instead of the fish `flatOrientation`, so bipeds stand. Knobs
    `Tuning.Creature.SHAMBLE_*`.
  - **Models — the CreaturePack (redesigned 2026-08-22 after the user called
    the procedural parts lackluster; re-import pending).** The three are now
    proper low-poly **Blender meshes** in a *second* pack alongside FishPack:
    `assets/creatures_gen.py` → `assets/creatures.glb`, objects
    `<Name>_Body/_Fins/_Eyes/_Marks` (Crab / Deckhand / Angler), imported as
    `ReplicatedStorage/Assets/CreaturePack`. Rows use `model="CreaturePack"` +
    `species=` (assembleSpecies picks them, **zero CreatureModel change** — the
    same path as fish species). Designs: crab has an **oversized "snapjaw"
    claw** + small claw, wide shell, 8 legs, eye stalks; the Angler fuses the
    drowned fisherman with an **anglerfish — a glowing lure (its `markColor`)
    on a stalk off a sou'wester**, plus a gaff. The procedural `buildCrab`/
    `buildZombie` (`shape=`) stay as the rough **pre-import fallback** (the
    zombie fallback faces sideways under the upright path — cosmetic, gone once
    the pack is imported). **The pack was authored in Blender and preview-
    rendered (`creatures_preview.png`) but not seen in Studio.** Neon lure is a
    possible follow-up (markColor is bright but SmoothPlastic, not emissive).
    **Facing gotcha (fixed):** the GLB import lands the built Blender **+X** at
    Roblox **-X**, but CreatureService points local **+X** at the player, so the
    first import charged/shambled at you *backwards*. `creatures_gen.py` now bakes
    a **180 deg yaw** into export (creatures built +X, flipped so +X arrives as
    Roblox +X). Any new creature must be authored the same way. Re-import needed.
  - **Drops (2026-08-22).** A creature row can carry `drops.materials` (a
    per-row override of the rarity `KILL_BY_RARITY` default, honoured in
    `MaterialService.onKilled`) and `drops.items` (rare finished-item drops).
    Two new rare materials in `Materials.luau`: `barnacle_chitin`,
    `cursed_bone` (no craftable gear consumes them yet — that's a later
    slice). Item drops are a new **`DropService`** (a third `Killed` listener,
    never touches the material/coin payouts): rolls each `drops.items` chance,
    grants an existing Rods/Weapons id via `InventoryService.grantItem`, fires
    the `ItemDropped` remote → client **`DropController`** shows a centre
    "You found: X!" banner. The Drowned Angler drops a `scale_blade` at 10%.
- **Enemies slice 1 (2026-08-22, user: "more enemies, original, creative,
  use the other enemy types"; unreviewed).** Eight new hostile rows, each
  its own archetype state machine in `CreatureService` (same shape as the
  rusher: `mode`/`modeStart`/`modeUntil` on the struct, every move through
  `resolveHorizontal`, one `PivotTo` per frame, `ARCHETYPE_UPDATERS` table
  dispatch; knobs in `Tuning.Creature` under "enemies slice"). The real fish
  rows were renamed to archetype **`flopper`** (user decision: they stay
  passive) — the old `drifter`/`charger`/`spitter` strings on them are gone.
  - **Tideline Skipper** (Uncommon, `charger`): windup → straight dash
    PAST the player (`CHARGE_OVERSHOOT`, one hit, no recoil; `Dashing`
    attr) → `turning` (`Exposed` attr; hits land ×`CHARGE_EXPOSED_DAMAGE_MULT`
    via `CreatureService.hitModifiers`, which CombatService now consults).
  - **Gullet Cod** (Uncommon, `spitter`): holds `SPIT_MIN..MAX_RANGE`,
    rears up, spits. The glob is a **server timer** (`creature.spit`,
    lands at the player's position at launch after `SPIT_FLIGHT`, resolved
    in `update()` whatever the cod is doing — `landSpit`); clients draw the
    arc + landing ripples from `CreatureEvent "spit"` and the hit as
    `"splash"`. No projectile parts on the server.
  - **Tidebomb Urchin** (Rare, `bloater`): every hit `ScaleTo`-swells it
    and starts a fuse (`onBloaterHit` from `damage()`); `BLOAT_HITS_TO_POP`
    or `BLOAT_FUSE` → `explode`: players AND creatures in `BLOAT_RADIUS`
    hurt/thrown (credited to `lastAttacker`), `"explode"` event, then
    `kill`. Fully shovable/launchable so you juggle it away. Chains.
  - **Moonbell Jelly** (Uncommon, `drifter`, stance upright): hovers at
    `DRIFT_HOVER` toward you, stings on contact; launch ×1.8, gravity ×0.16
    (`GRAVITY_MULT_BY_ARCHETYPE`, new), knockback ×0.05; `updateAirborne`
    lands it at hover height and skips the `Flops` tick.
  - **Sand Lurker** (Rare, `burrower`): surfaced → sinks (`Buried` attr;
    `untargetable` — `inRange` and `damage()` both refuse, explosions
    included) → tunnels at you under the sand → bursts up within
    `BURROW_AMBUSH_RADIUS` (`"emerge"`). Client hides the parts with
    `LocalTransparencyModifier`; `CombatFeedbackController` hides the bar
    while `Buried`.
  - **Pearl Mimic** (Rare, `mimic`, stance upright): shut + `untargetable`
    (so Health never changes and the bar never appears) until a player is
    within `MIMIC_SNAP_RADIUS` → lid cracks (tell) → `"snap"` bite → `Open`
    for `MIMIC_OPEN_TIME` (hittable). **The lid is the model's single
    `Fish_Fins` part**, hinged server-side about `MIMIC_HINGE_BACK` (the
    art species must keep that). Drops pearls.
  - **Pickpocket Hermit** (Uncommon, `thief`): chase → contact steals
    `THIEF_STEAL_FRACTION` of coins (`ProgressionService.spendCoins`, lazily
    required — it boots after CreatureService), `creature.loot`, `"steal"`
    event (victim gets a "-N coins" pop via `ProgressionController.pop`),
    resets `lastFoughtAt` → zig-zag flee → chase again. **`Killed` now
    carries a 4th value `{ loot }`**; `ProgressionService.onKilled` pays it
    back ×(1+`THIEF_BONUS`). Lost if it lingers out — by design.
  - **Voltray** (Epic, `pulser`): slides at you; `Charging` attr for
    `PULSE_CHARGE` (hitting it then shocks the attacker —
    `hitModifiers` → CombatService → `PlayerService.damage`), then
    `"pulse"`: ring damage in `PULSE_RADIUS`.
  - **Engine changes that carry:** `kill()` no longer swap-removes while
    `update()` is walking the array (`updating` flag; dead structs are
    swept at the top of the walk) — explosions can kill from inside the
    loop safely; `PlayerService.damage(..., opts)` gained `bypassIframe`
    for telegraphed bursts (explosion / snap / burst / pulse / splash)
    so a stray contact tick can't swallow them; `AOE_HEIGHT_TOLERANCE`
    bounds area hits vertically; new per-archetype tables `GRAVITY_MULT_`
    + entries in `KNOCKBACK_MULT_`/`LAUNCH_MULT_BY_ARCHETYPE`.
  - **Client:** new `CreatureEventController` (ORDER last) — watches
    `Dashing`/`Exposed`/`Buried`/`Open`/`Charging` on creature Models
    (trail + sand puffs, dazed sparks, hide + sand trail, pearl/organ glow
    via `Material.Neon` — **it never writes part Color**, because
    CombatFeedbackController caches/restores colours) and handles
    `CreatureEvent` kinds `spit/splash/explode/emerge/snap/steal/pulse`
    with new `Vfx.shockwave/flash/arcPoint` and a pooled glob. Camera kick
    goes through the new `CombatVfxController.kick` export; a full-screen
    flash when you're inside a blast.
  - **Stand-ins** (`CreatureModel` `BUILDERS`: skipper, gulletcod, urchin
    (= puffer with 0.9 spines), jelly, lurker, mimic, hermit, ray): flat
    ones authored Z > X > Y, front +Z; jelly + mimic upright (facing +X —
    the mimic's gape is at +X and its hinge on −X, matching the mesh).
  - **Art (slice 2, 2026-08-22, user: "models are mid — make them full,
    low-poly, high quality"; re-import pending).** `creatures_gen.py`
    builds all eight as CreaturePack species `Skipper / GulletCod / Urchin /
    Jelly / Lurker / Mimic / Hermit / Voltray` (+ the original Crab /
    Deckhand / Angler, byte-identical): revolved bodies (`revolve`), fin
    plates (`plate`), limb chains (`chain`), a fluted clam valve
    (`fluted_dome`), a gridded ray disc with real volume; ~4,750 polys for
    the pack. New builder helpers live at the top of the script; every
    builder notes its bbox ordering and `report_bbox` prints it on each run
    (`BAD` = flatOrientation would mis-lay it). The preview is a 4×3 grid
    (enemies front, originals behind). **The mimic's lid is its `_Fins`
    object**, hinged by `CreatureService` 0.9 behind the centre on the
    facing (X) axis, rotating about Z — fixed from the stand-in's old
    `-Z`/about-X assumption in the same pass.
  - **Likely tuning asks:** every number above; the urchin's swell size;
    the lurker's buried transparency vs. the mound trail; spit flight time.
- **Every creature that comes out of the water must be killed** (user) —
  there is no auto-collect tier; rarity scales the fight and payout. The
  plan's "commons flop and auto-collect" is struck.
- **Island bosses (2026-08-22; user: "a boss for each island to fight
  before you move on… only at level 15 with the island's best rod and
  weapon… a load of different attacks… fairly difficult… big and
  intimidating").** One boss per island, as data:
  - **`Shared/Data/Bosses.luau`** — `Bosses.items.<id>` = `{ name,
    shortName, creature (Creatures row id), islandId, gate { level, rod,
    weapon }, arena { offset (relative to the island), radius }, aggro,
    standoff, submerge, riseDepth/riseTime, speed, turnRate,
    attackGapMin/Max, enrageBelow/enrageCooldownMult/enrageDamageMult,
    phases = { { below = hpFraction, attacks = {names} } }, attacks =
    { name = { windup, duration, recover, cooldown, damage = {lo,hi}, … } } }`
    + `Bosses.byIsland`. **Brinejaw, the Drowned Leviathan** guards
    `tropical`: gate Lv 15 + `bonecaster_rod` + `drowncleaver`; **9,000 HP at
    body.scale 1.5 (~26 studs)** — user: "bigger, beefier, genuinely hard even
    with the best weapon" (≈2–3 min at Drowncleaver DPS); arena 28 studs
    round a point 210 studs down +Z — the open water just past the **round
    arena deck** at the dock's end (`World.ARENA_CENTER`, z 122..198), so
    it's fought from the planks and can haul itself onto the rim. Melee
    reach (14–16) is measured to the creature's PIVOT, so `CreatureService
    .inRange` subtracts a per-creature `hitRadius` (Bosses field 6 × scale
    = 9: reach is to its hide); `standoff` 14.
  - **The row** `Creatures.items.brinejaw`: rarity **"Boss"** (no
    `Tuning.Rarity.WEIGHTS` entry → never rolls from a cast; carries its own
    `rewards` + `drops`), archetype `"boss"`, `boss = "brinejaw"`, stance
    upright, `shape = "leviathan"` stand-in, species `Leviathan`.
  - **The engine** (`CreatureService`, block above `ARCHETYPE_UPDATERS`):
    `updateBoss` — first frame anchors the arena, sets `BossName`, fires
    `bossRise` and plays the rise (untargetable); then **prowl** (face +
    close to `standoff`, clamped to the arena circle, breathing) and one
    **attack** at a time from `pickBossAttack` (random from the current
    phase's list, never the same twice running, never one on cooldown;
    `forcedAttack` for `follow` chains). Every attack runs
    windup → strike → recover through `updateBossAttack`, with a handler in
    `BOSS_ATTACKS`: `windup(pose)`, `fire` (once), `strike` (per frame),
    `finish` (once), `recover(pose)`. The eight: **snap** (lunge + front
    cone), **tail** (everything NOT in the front cone —
    `damagePlayersInCone` with `invert`), **volley** (5 brine globs around
    the player via the per-creature **`globs` list**, landed in `update()`),
    **slam** (rear up, ring), **pull** (`"pull"` event — clients drag their
    own character with a `VectorForce`; follows with a forced snap),
    **brood** (spawns 3 minion rows thrown at the player), **dive**
    (`setBuried` → untargetable + hidden, tunnels under the player, bursts
    up: `"emerge"` with `big = true`), **spines** (8 bone spines rain around
    the player). Enrage below 35%: `Enraged` attr, cooldowns ×0.6, damage
    ×1.3. Boss is exempt from LINGER, `boss = 0` in the knockback/launch
    tables (never shoved/juggled — a juggled boss can't attack).
    `damage()` now records `creature.participants`; `kill()` fires Killed
    with `{ loot, participants, …spawn's extra }` and `spawn` takes an
    optional 5th `extra` table (2b's bait bounty rides it).
  - **`BossService`** (server, after Crafting): every 1 s, per boss with no
    live one on its island, raises it (`CreatureService.spawn(row, arena,
    nil, "Neutral")`) for the first player on the island (radius + 160) who
    passes the gate and hasn't cleared it. On Killed: every participant gets
    the row's rewards (killer already paid via Progression) and the
    replicated **`Cleared_<islandId>`** Player attribute plus the permanent
    **`Heart_<bossId>`** trophy attribute (gates the island's Legendary
    crafts via `Recipe.requiresHearts` — owned, never spent); fires
    `bossDown` with what it unlocked. Both persist through `DataService`.
  - **Travel gate:** `WorldService.handleTeleport` refuses island N+1 with
    "Defeat <shortName> first" unless `Cleared_<islandN>`; `Islands.items
    .<id>.boss` names the guard.
  - **Client:** `BossHudController` (ORDER last) — top-centre name + bar
    off `BossName`/`Health`/`MaxHealth`/`Enraged` (bar goes red), a title
    card on `bossRise`, "ISLAND CLEARED — <next island> is open" on
    `bossDown`. `CreatureEventController` — `Enraged` lights the marks and
    flickers; kinds `bossRise / telegraph (per attack) / bossSnap / sweep /
    slam / pull / spine / spineHit / summon / bossDive / enrage / bossDown`;
    the glob pool grew to 14 and can fly bone spines; buried puffs are foam
    over water. Sfx: `bossRise/bossRoar/bossTell/bossSnap/bossSweep/
    bossSlam/bossDown`.
  - **Art:** `CreatureModel.buildLeviathan` stand-in (torso first = pivot;
    head 5 studs forward) and the Blender `Leviathan` species in
    `creatures_gen.py` (~17×8.6×7.6 bbox, 570 polys; marks = lure bulb,
    gill slits, throat — Neon when enraged). **Re-import `creatures.glb`**.
  - **Playtest pass (2026-08-22, via 2b):** *tail never hit* — it spared the
    front cone but the boss faces its target, so a solo player was always
    in front; now a full circle (radius 21) dodged by distance, with a
    pulsing ring tell. *Slam undodgeable* — 33 radius from a 14 stand-off
    in 1.15 s can't be outrun; now 26 / 1.6 s (~0.8 s to react). *Dive
    burst short* — the obstacle-clamped mover stopped it at the arena
    deck's collision; underwater it now moves obstacle-free via
    `groundedPos`, tracks the live position, and for the last `lock` 0.9 s
    snaps under the player's feet with a `telegraph kind="burst"` ring,
    then bursts (radius 13). Boss area attacks use `BOSS_HEIGHT_TOLERANCE`
    14 (players stand on the deck ~5 studs above its pivot; the default 6
    was a coin toss). `damagePlayersInRadius` gained an optional
    `heightTolerance` arg.
  - **Summoned, not ambient (2026-08-23, via 2b: "the boss should be
    fished up").** The auto-raise loop is gone; `BossService.summonFor
    (player) -> (ok, reason?)` raises the boss of the island the player is
    on at its arena, refusing with a player-facing reason when there's no
    boss here / it's already defeated / one is live / level < gate.level.
    FishingService (2f) calls it when a cast uses the capstone bait
    **Leviathan's Call** (`Bait.luau`, Lv 15, crafted from every creature's
    signature drop — 2b) and consumes the bait only on ok. **The bait
    replaced the gear gate** (user decision): `Bosses.gate = { level = 15 }`;
    `rod`/`weapon` are optional fields `qualifies` checks only if set.
  - **Testing without grinding to Lv 15:** admin `P` → grant level/coins,
    craft both, walk to the deck's end; or spawn `brinejaw` from the admin
    creature list (it then rises wherever it lands). Likely tuning asks:
    every number in the attack book, the arena offset, the pull strength
    (30 studs/s²), the standoff.

### Gear perks — signature abilities (2026-08-22)

Every Rare+ rod and weapon has a named ability, plus three Uncommons. They are
**data**: a `perk` block on the row (`Rods.Perk` / `Weapons.Perk`), each field
read by exactly one place. So a new perk is a row edit plus one hook, and the
inventory + crafting cards render `perk.name` / `perk.description` on their own.

**Rods** (effects in `FishingService` / `Minigames.reel` / `CastAim`):
- Bamboo — **First Bend**: `freeMisses = 1`, one miss before zones shrink.
- Angler's — **Chum Line**: `streakLuck`/`streakMax`; luck grows per cast seen
  through, and `castStreak` is **wiped by `cancelCast`** (rod swap / timeout).
- Abyssal — **Abyssal Pull**: its `minRarity` floor **plus** `castRange` 1.6
  (Deep Line), applied via `CastAim.rangeFor(rodData)`. **Both sides pass the
  rod** — the client must gate its aim by the same number the server
  validates, or the player is told "get closer" about water the server would
  happily accept.
- Reefmaw — **Never Snaps**: `noShrink`, zones never shrink at all.
- Bonecaster — **Drowned Tide**: its `minRarity` floor **plus**
  `callsArchetype = "shambler"`. Archetypes in `Rods.LOCKED_ARCHETYPES` are
  dropped from every OTHER rod's roll, so the drowned are gated behind
  crafting this rod (not merely rarer), and weighted up by
  `CALLED_ARCHETYPE_WEIGHT` when it is held.
- Reel forgiveness rides in the **config** (`Minigames.reel.configFor` →
  `Reel.shrinkFor(config, misses)`, called by BOTH sides). It has to: client
  prediction and server scoring would otherwise draw different zones mid-cast.

**Weapons** (effects in `CombatService`, knobs in `Tuning.Perks`):
- Scaleblade — **Frenzy**: consecutive landed hits ramp damage
  (`FRENZY_STEP`/`_MAX`/`_WINDOW`); the chain lives per player in CombatService.
- Shellcrusher — **Uproot**: `applyKnockback`'s 5th arg overrides an
  archetype's launch pin, so it juggles enemies that normally stay grounded.
  `Tuning.Perks.UPROOT_IMMUNE` (boss) still wins. Implemented as an immunity
  table rather than multiplying the archetype mult — multiplying by 0 would
  make Uproot a no-op on every pinned hostile, i.e. the whole ability.
  **This also rescues the big `knockback` numbers**, which did almost nothing
  in real fights once hostiles were pinned.
- Drowncleaver — **Brine Rot**: `CreatureService.poison` stacks a DoT
  (`POISON_TICK`, `POISON_MAX_STACKS`), ticked in the update walk beside the
  glob/fuse timers. Every tick goes through `damage(..., { ignoreUntargetable
  = true })`, so participants/kill/Killed stay on the one path **and the rot
  burns through a boss's dive or a lurker's burrow** — the intended counter to
  those untargetable phases (see the boss Gotcha). Direct hits must never pass
  that flag; being unhittable is the point of the phase.

**Gear from the later creature mats (2026-08-22).** Two rods, three weapons and
three baits built from what the 8 new enemies + Brinejaw drop:
- Rods: **Voltline** (Epic — volt_gland/nacre/pearl; Live Wire = Rare floor +
  1.3 cast range) and **Brineheart** (Legendary — brineheart/volt_gland/
  cursed_bone; The Sea Answers = Epic floor + 1.8 range + noShrink).
- Weapons: **Tidebomb Maul** (Rare, `cleave`), **Voltfang** (Epic, `execute`),
  **Heartrender** (Legendary, `lifesteal`, needs the boss's heart). Three new
  perk fields, all in `CombatService` + `Tuning.Perks`; `lifesteal` added
  `PlayerService.heal` (deliberately does NOT reset the regen clock).
- Baits: **Glowchum**, **Venom Roe**, **Gilded Chum**.
- **`lootLuck` / `calls` / `hard` / `double` / `lure` / `ease` are GONE**
  (2026-08-23). They were declared in Bait.luau, documented in its header as
  working, and read by nothing in `src` — five baits advertised effects that
  never ran. `baitTag`, the creature-side half of `calls`, never existed at
  all. Deleted along with `applyEase` and the `lure` weighting in
  `rollCreature`, both of which were live code no bait could reach. **Don't
  reintroduce a field here before the code that reads it exists** — that is
  exactly how this happened.
- **Bait effects must be VISIBLE (user, 2026-08-22).** The original three were
  luck/reward multipliers and the user found them pointless to craft — you
  use one, catch a fish, and can't tell it did anything. The rule now: a bait
  should answer "what will I SEE that's different?", not "your odds are 1.35×".
  The three wired effects, all new fields clear of 2b's pending set:
  - `stun = <seconds>` (Glowchum) — the catch lands dazed. `CreatureService`
    pre-empts the archetype updater exactly like the juggle does (a
    `stunnedUntil` branch above the dispatch), so even a hostile just flops
    and takes free hits; sets a `Stunned` attribute for a future client tell.
  - `hostileOnly = true` (Venom Roe) — the "danger bait": `allowedRows` drops
    every `flopper` row, so the catch always fights back. Worth using because
    only hostiles drop the advanced mats. Deliberately NOT 2b's `calls`
    (which targets a family) — the two coexist.
  - `guaranteedDrop = true` (Gilded Chum) — rides `spawn`'s `extra` bag to
    the Killed event; `MaterialService.onKilled` grants the TOP of each
    material range instead of rolling. The way to farm a specific material.
  - `summonsBoss = "<boss id>"` (Leviathan's Call, added by `roblox-game-2b`) —
    the capstone. Not a fishing modifier: the cast summons the boss instead of
    rolling a catch. Recipe is a signature drop from all 12 creatures, so it's
    a trophy of the whole bestiary. **Wiring still owed by this session**: the
    `FishingService` hook (below).
  - Both menus print these as plain words ("Stunned 6s", "Always hostile",
    "Guaranteed", "Summons Brinejaw") rather than percentages, for the same
    visibility reason.

### The five rebuilt baits (2026-08-23)

The baits whose effects were dead, given mechanics you watch happen. Knobs in
`Tuning.Bait`.

- **Chum** `shoal = 1` — a spare passive Common is thrown up from a ring
  around the bobber alongside the catch. Deliberately the plainest effect in
  the file; it's a 15-coin Common.
- **Bloodbait** `chain = 3` (+ `hostileOnly`) — each kill draws the next
  hostile to the same spot. Driven off the **Killed event**, not the cast: by
  the time link three surfaces the cast is long resolved, so the state rides
  the spawn `extra` bag, which `CreatureService` copies into Killed's info
  (`chain` / `chainLink` / `chainRod`). `kill()` now also reports `position`
  so the next one can surface where the last one died. Escalation is in the
  ROLL (`CHAIN_LUCK_STEP` per link), not a payout multiplier — a rarer
  creature is both the reward and the thing you see.
- **Gravelure** `salvage = true` — a cast with no catch at all: materials +
  coins straight out of the water, scaled by the minigame grade. The only
  non-combat cast in the game. Reuses the no-creature resolve path built for
  the boss summon; needs its own client banner because the normal one requires
  a creature.
- **Frenzy Bait** `enrage = true` — the grade is **overridden** to `Enraged`
  (it's a named tier, not a number, so it can't be multiplied). That tier
  already pays 1.5×, so `ENRAGE_BOUNTY` only tops it up to about double.
- **Split Roe** `hatchling = 60` — the game's only friendly creature. See
  below; it needed real support in CreatureService.

### The companion (friendly creatures)

New `companion` archetype + a `friendly` flag, because nothing in the creature
system assumed a creature could be on the player's side. Four things had to
change, each of which would have been a bug on its own:

- **`inRange` skips friendly.** CombatService swings at the *nearest* thing it
  returns, so otherwise you punch your own pet the moment it gets between you
  and the enemy. It is still damageable through `damage()` — untargetable by
  the player, not invulnerable, so an urchin blast still catches it.
- **`expiresAt` despawn.** A companion is never "left alone", so the LINGER
  timer would never fire and it would live forever. It leaves on its own clock;
  `friendly` is excluded from LINGER.
- **Knockback and launch multipliers are 0** for `companion` — a pet juggled
  into the air is a pet that can't help.
- **`Friendly` attribute** on the model, for clients to draw it as an ally
  rather than a target (`roblox-game-83` owns that half in
  CombatFeedbackController).
- Its kills are credited to `creature.owner`, so coins/XP/materials follow the
  player who brought it up.
- The `hatchling` row in Creatures.luau uses rarity **"Companion"** — a bucket
  no roll walks, the same trick the boss row uses — and carries zero `rewards`
  deliberately, because a row with no reward table for its rarity makes
  ProgressionService warn when something kills it.

`bounty` is a new general per-kill reward multiplier in the `extra` bag, read
by both ProgressionService and MaterialService.

### The boss-summon cast (done, 2026-08-23)

`onRequestCast` branches on `summonsBoss` above the ordinary bait spend. Three
invariants, each of which was a real trap:

- **The gate is checked, and the count verified, BEFORE the bait is consumed.**
  Bait is normally spent right after landing validation so nobody can
  cancel-and-reroll once a minigame reveals the rarity — but this bait costs a
  drop from all twelve creatures, so a refusal must cost nothing. Order:
  normal rejections → count → `summonFor` → spend. Consume only on `ok`.
- **A boss cast never enters the minigame path.** There's no catch, so firing
  CastAccepted would open a reel bar for a boss. It resolves immediately with
  `{ summoned = <boss id> }` and a fresh cast id.
- **That resolve is what clears the client's `pendingCast`.** The player has
  already started the swing when the request goes out; `endCast()` runs on any
  resolve and clears it. Skipping the resolve (or only firing CastRejected on
  success paths) would strand them unable to cast again.

Banner: "Brinejaw answers the call." in the bait's teal — deliberately not a
rarity colour, because it isn't a catch.

`BossService.summonFor(player, at?) -> (ok, reason?)` returns player-facing
reason strings; consume only on `ok == true`.

**The gate is level 15 + the bait, and nothing else** (user, 2026-08-23). The
original `Bosses.gate` also demanded the Bonecaster Rod and Drowncleaver;
`roblox-game-83` is nilling those. Don't reintroduce a gear requirement — the
bait recipe already costs a signature drop from all twelve creatures, which
proves far more progress than owning two items, and a gear wall would refuse
the player at the dock *after* they'd spent the craft.
- **Voltrays are deliberately NOT gated behind the Voltline rod** (user) —
  only the drowned are gated, behind the Bonecaster.
- Meshes: new variants in `rod_gen.py` (Voltline, Brineheart) and
  `weapon_gen.py` (TidebombMaul, Voltfang, Heartrender); `rod.glb` /
  `weapon.glb` regenerated. **`Assets.rbxm` is stale until re-imported** — the
  rows fall back to procedural stand-ins meanwhile, so nothing is invisible.

### Combat

- **Weapons are rows** in `Shared/Data/Weapons.luau` (2026-08-22): `fists`
  (numbers still *reference* `Tuning.Combat` — `PUNCH_COOLDOWN` 0.14 s,
  user asked for ~3× the original rate; `PUNCH_REACH` 14; 6–10 dmg), plus
  two craftable ones: **`driftwood_club`** (Lv 3, 80 coins, 10 driftwood +
  4 kelp fiber; 26–38 dmg @ 0.45 s, reach 15, knockback 26, swing `chop`)
  and **`scale_blade`** "Scaleblade" (Lv 7, 260 coins, 6 driftwood + 12
  fish scale + 1 pearl; 13–19 dmg @ 0.2 s, reach 14, knockback 12, swing
  `slash`). Balance target: fists ≈57 dps, club ≈71, blade ≈80 (against a
  150 HP puffer). Each row carries `damage {min,max}` / `cooldown` / `reach`
  / `knockback`, an optional `swing` (a `WeaponSwingAnim` clip name; nil =
  punch clips) and `model` (`shape` club|blade, optional `variant`+`model` for
  a WeaponPack mesh, `length`, `grip`, `color`, `accent`, `wrap`, optional
  `glow`+`neon`; nil = bare hands), and a `recipe` in the rod shape.
  **Melee only — never a ranged row** (binding decision). Held models come from
  `Shared/Modules/WeaponModel.luau` (authored along +Y, `Weapon_Grip` at
  `y = grip`, `HOLD_OFFSET` for the welded copy): a **WeaponPack mesh variant**
  when the row names one, else **procedural** club/blade parts.
- **Swing:** `CombatController` (client) binds left-click/tap while a
  weapon is out, gates on the equipped row's `cooldown`, plays the matching
  viewmodel's clip (`FistsViewmodelController.punch()` for fists,
  `WeaponViewmodelController.swing(row.swing)` otherwise; cue `punchSwing`
  / `weaponSwing`), and at the clip's `HIT_TIME` fires `RequestAttack`.
  `CombatService` (server) re-checks kind + the row's cooldown, takes the
  nearest creature within the row's `reach` of the root, rolls the row's
  damage into `CreatureService.damage`, applies the row's `knockback` on a
  non-killing hit, computes the contact point on the body's box, and fires
  `CreatureHit` (hitPoint, direction, killed, attackerUserId) to all clients.
  An unknown equipped weapon id falls back to the fists row on both sides.
  Hit VFX/SFX are the same for every weapon; no screen-space targeting yet.
  `WeaponService` (server, after `RodService`) welds `EquippedWeapon` (attr
  `WeaponId`) to the right hand for other players when a modelled weapon is
  out, and removes it otherwise.
- **Feedback** (`CombatFeedbackController`, entirely attribute-driven off
  `Health`/`MaxHealth`, no coupling to the damage source): a BillboardGui
  health bar (hidden until first hit, green→red), a red tint flash on the
  parts, floating damage numbers from a fixed pool of world anchors that
  outlive the fish. **Impact VFX** (`CombatVfxController`, off
  `CreatureHit`): pooled neon parts in `Workspace.CombatVfx` — collapsing
  flash sphere, expanding ring facing the puncher, shards flung back with
  drag; a random camera shake plus a **directional camera nod** for the
  attacker only (RenderStep at Camera+1 so the viewmodel shakes with it);
  kills scale by `KILL_SCALE`. **SFX:** punch cues are all the built-in
  `action_jump_land` at different pitches — `punchSwing` (2D), a landed hit
  plays `hitCrack` + `hitThump` together, kills `killCrack`/`killThump`. The
  user explicitly removed wet/splat sounds from combat ("should feel like
  I'm punching the fish"); the flop `splat` is deliberately kept slimy.
  Most of this is **not yet reviewed in Studio** — likely asks: trail
  strength, shard count, shake, volumes.
- **Player health** (`PlayerService`, server): rides on the character's real
  `Humanoid` (the no-Humanoid rule is about creatures; leaning on the real
  one is why death/respawn just work) — sets `MaxHealth`/`Health` =
  `Tuning.Player.MAX_HEALTH` (100) on spawn, `damage(player, amount,
  source?)` `TakeDamage`s through an `IFRAME` (0.35 s) so overlaps can't
  multi-drain, out-of-combat regen (`REGEN_DELAY` 7 s, `REGEN_RATE` 6/s) on
  Heartbeat. It is the **only** way anything hurts the player. Boots before
  `CreatureService`, which requires it. **HUD** (`PlayerHudController`):
  a **minimal green pill top-right (200×10) that shrinks on a hit — no
  panel, no text, stays green** (the user asked for "sleek"; the green→red
  lerp and the cur/max number were removed), plus a red full-screen flash
  on any health drop. Reads the local Humanoid directly (no remote),
  re-hooks on respawn, disables the default Health CoreGui. **The rusher
  and the puffer are unreviewed** — likely asks: rush speed/damage feel,
  puffer look.

### Progression

`ProgressionService` (server, after `CreatureService`) listens to `Killed`
and pays `Tuning.Rewards.BY_RARITY[rarity]` (coins rolled in a range, flat
XP) × `Tuning.Grade[grade].rewardMult` (Enraged pays 1.5×, per the plan); a
row's own `rewards` field overrides (none do). Level curve
`Shared/Modules/Progression.xpToNext(level) = XP_BASE × level^XP_EXPONENT`,
XP rolls over, `MAX_LEVEL` 50. Totals are **replicated attributes on the
Player** (`Progression.ATTR`: Coins / XP / Level / XPToNext); the only
remote is `RewardGranted` (server → killer) for the HUD pop. Server API:
`getState`, `addCoins`, `spendCoins(player, n) → bool` (for crafting),
`addXp → levelsGained`. `ProgressionController` draws the **bottom-right**
stack (coins, LV / XP caption, thin XP bar; no panel box — user: "cleaner
and sleeker") and a "LEVEL N!" banner at y=84 (fishing banner is at y=40;
health is top-right). **Reward pops (user, 2026-08-22):** one short rising
line per thing gained, out of the top of that stack — "+N coins" **gold**,
"+N XP" **blue** (`Theme.Color.accent`, the XP bar's colour), and "+N
<Material>" in the material's swatch colour off `MaterialGranted` — each
pop taking the next slot up (`POP_STAGGER`) so a kill reads as a column:
coins, XP, scale, pearl. `pushPop(text, color)` is the one path; knobs
`POP_*`. **In-memory only; levels gate crafting only; no sound on purpose.
Unreviewed.**

**Admin cheat panel** (`AdminService` / `AdminController`, `AdminGrant` +
`AdminSpawn` remotes; session 9b, 2026-08-22): **`P`** (was F1 - F1 opens a
Roblox overlay), gated server-side to Studio + `ADMIN_USER_IDS` + the place
creator (`IsAdmin` Player attribute). Grant buttons give 100k coins / XP and
9999 of each material, repeatable, through the normal `ProgressionService` /
`MaterialService` APIs so the HUD and menus update live. A **Spawn Creature**
button opens a rarity-coloured scrolling list of every `Creatures.items` row
(sorted by tier then name, via `Shared/Modules/Rarity`); clicking one fires
`AdminSpawn`, and the server spawns it `SPAWN_DISTANCE` (18) studs in front
of the caller with target = their root, so it arcs in like a real catch
(`CreatureService.spawn(row, front, rootPos, "Neutral")` - fish and hostiles
alike). Dev tooling only.

**Admin panel round 2 (2026-08-27, with the voyage-arc map; unreviewed):**
- **All Items** (`AdminGrant "items"`): every rod + weapon via
  `InventoryService.grantItem` (idempotent - owned-once) and 99 of every
  bait via `BaitService.grant`.
- **Unlock World** (`AdminGrant "unlock"`): max level (`addXp` 10M, capped
  at MAX_LEVEL), `Cleared_<id>` for every island, `Heart_<bossId>` for every
  boss, and the Stormbreaker Keel via `BoatService.grantTier` (through the
  service so any spawned hull retires properly). These are the REAL
  progression attributes, so DataService persists them - there is no relock;
  don't press it on a save you care about. **Give Everything** now also runs
  both.
- **Flight** (panel button or **`F`**, admins only; non-admins' F passes
  through): client-side flythrough in `AdminController` - a LinearVelocity
  on the root (huge force = dictated velocity, gravity included; character
  stays unanchored so it replicates) driven from `Humanoid.MoveDirection`
  remapped through the FULL camera frame, so W flies where you look, pitch
  included; idle = hover. 150 studs/s, **LeftShift = 600** (sized to the
  4,000-8,700-stud voyage legs). Collision stays on (no noclip). Refused
  while seated (the seat weld would drag the boat); dropped on respawn and
  on losing admin. Knobs `FLY_*` at the top of the controller.
- **Travel To Island** now lists site entries too (the Maelstrom was
  invisible to admin travel - it sits outside `Islands.order`).

### Crafting: materials (earn side) + rod / weapon crafting

Design forks the user chose (plan file above): materials are earned **two
ways** — basic mats (`driftwood`, `kelp_fiber`) on **every cast resolve**
("the line drags up debris"), rare mats (`fish_scale`, `pearl`) **dropped
on kill**, scaled by rarity + grade (the reward for landing and fighting
the catch); and recipes (Slice 2) will cost **materials + coins + a level
gate**, for rods now and weapons later — build it item-agnostic.

- `Shared/Data/Materials.luau`: 4 rows, id-keyed like Rods/Creatures
  (`tier` basic|rare, `color`), plus `Materials.order` for stable UI.
  `Tuning.Materials` (`CAST_GRANT`, `KILL_BY_RARITY`).
- `MaterialService` (server; in ORDER between `CreatureService` and
  `FishingService` — it listens to `Killed` and `FishingService` requires
  it): in-memory `{[Player]: {[matId]: count}}`; `grant`, `grantCast`,
  `getCount`, `getAll`, `spend` (for Slice 2). Replicates with the inventory's
  pull-then-push pattern — `GetMaterials` / `MaterialsUpdated` / a
  `MaterialGranted` pop — **not an attribute, because a table can't ride
  one.** In-memory only.
- **Shown inside the inventory** (user request, 2026-08-22 — the original
  bottom-left HUD chip stack and its `MaterialsController` were removed):
  `InventoryController` pulls `GetMaterials` on load, subscribes to
  `MaterialsUpdated`, and draws a **Materials strip** under the item grid —
  one slot-sized card per `Materials.order` entry (colour dot, count, name;
  dimmed at zero). Clicking a card fills the detail panel with the
  material's name × count and description, with the rod stats group
  hidden. `MaterialGranted` is consumed by `ProgressionController` (user
  request, 2026-08-22): every material gained on a cast or kill gets its own
  "+N Name" pop in the material's colour, in the **bottom-right reward pop
  stack** alongside the coin / XP pops (see Progression).
- **Unreviewed in Studio.**
- **Crafting — Slice 2, built (2026-08-22, unreviewed).** Three new rod rows
  in `Rods.luau` (`bamboo_rod` control-1.25 / `anglers_rod` luck-1.4 /
  `abyssal_rod` power-1.3), each with a `recipe = {requiresLevel, coins,
  materials}` field (new `Recipe` type; the starter has none). The stats do
  the reel differentiating via `reelConfigFor`.
- **Distinct rod meshes (2026-08-22, unreviewed / re-import pending).** All
  rods are now variants in one **RodPack** — `assets/rod_gen.py` is a
  parametrised generator producing Twig / Bamboo / Angler / Abyssal side by
  side into a single `assets/rod.glb` (the FishPack pattern, one import).
  `RodModel.build` clones a variant's parts out by name
  (`assembleVariant`, `<Variant>_Twig/_Grip/_Trim/_Line/_BobberTop/_BobberBottom`
  → generic `Rod_*`) and recolours **every part** from the rod row's
  `model.colors` (keys `twig/grip/trim/line/bobberTop/bobberBottom`, defaults
  for any missing) and marks `model.neon` parts as Neon. `run rod_gen.py ...
  rod.glb preview` writes `rod_preview.png`.
  **User must re-import:** import `rod.glb` as `ReplicatedStorage/Assets/RodPack`,
  delete the old `TwigRod` model, re-export `Assets.rbxm`. Until then every
  rod falls back to the plain-cylinder stand-in. `twig_rod.glb` deleted.
- **Rod look pass (2026-08-22, user: "make them look cooler", unreviewed;
  re-import pending).** Each variant now has a sixth `_Trim` part (guides,
  bands, tip ring, reel, pommel cap) and its own line + float shape
  (`FLOATS` profiles, revolved): Twig = twine lashings + wire loops + round
  red/white bobber; Bamboo = brass ferrules/guides/tip ring, butt cap, quill
  float; **Angler** = varnished blank, cork handle + steel reel seat, a
  **spinning reel** hung underneath, six guides, pear float; **Abyssal** =
  flattened (`flatten` 0.55) black-iron blade that **hooks forward**
  (`hook`), backswept barbs, **glowing teal** collars + tip ring, spiked
  drum reel + pommel spike (in `_Grip`, dark), and an anglerfish
  **lantern** lure (glowing orb + iron cage). Hardware sits on Blender −y =
  the underside in the hold. ~2,500 polys for the whole pack. Likely
  tuning asks: hook amount, reel size, glow colour.
- `CraftingService` (server, last in ORDER — requires Inventory + Material +
  Progression) handles `RequestCraft(itemId)`: looks the id up in
  `Rods.items` **or** `Weapons.items`, checks recipe exists, not already
  owned, `level >= requiresLevel`, coins, then spends **mats then coins**
  (coins peeked first so nothing yields between checks and spends —
  atomic), `grantItem`s it, fires `CraftResult {ok, itemId, reason?}`.
- **Multi-rod / multi-weapon ownership** in `InventoryService`:
  `grantItem`, `ownsItem`, `setEquippedRod(player, rodId)` /
  `setEquippedWeapon(player, weaponId)` (each fires the existing
  `onEquipChanged` listeners when that kind is in hand, so the world model
  re-welds and the viewmodel rebuilds), and `RequestEquipRod` /
  `RequestEquipWeapon` remotes. The choices are published as the
  **`Equipment.ROD_ATTRIBUTE` ("EquippedRodId")** and
  **`Equipment.WEAPON_ATTRIBUTE` ("EquippedWeaponId")** Player attributes —
  NOT "EquippedRod"/"EquippedWeapon" (those are the welded Models' names,
  `RodService.EQUIPPED_NAME` / `WeaponService.EQUIPPED_NAME`).
  `FishingService` abandons an active cast on **any** equip-change (a rod
  swap, not just putting the rod away — the reel config is per-rod).
- `CraftingController` (client, `C` key) — a modal cloned from
  `InventoryController`, now with **Rods | Weapons tabs** (grid of every
  item on the open tab left, detail right; per-tab stat rows: rod
  luck/power/control, weapon damage / swings per sec / reach). Detail shows
  state: owned+in-hand → "Equipped", owned → an Equip button
  (`RequestEquipRod` / `RequestEquipWeapon`), not owned → the recipe with
  each requirement green/red against your live counts and a Craft button
  gated on all being met; fists are owned + not craftable. Reads owned via
  `GetInventory`/`InventoryUpdated`, materials via
  `GetMaterials`/`MaterialsUpdated`, level/coins/equipped choices off the
  replicated attributes, so it stays live while open. Everything kind-
  specific lives on the `TABS` entries. Still **in-memory only**.
- **Weapon crafting — built (2026-08-22, unreviewed).** See the weapon rows
  under Combat. Likely tuning asks: how the club/blade look and sit in the
  hand, swing feel, damage/cooldown numbers.
- **Deferred:** weapon-specific hit VFX/SFX. (Equip-from-inventory — done,
  see Inventory; distinct rod meshes — done, see the RodPack note.)

### UI kit (2026-08-23 overhaul)

User: "completely overhaul the UI… more on theme and detailed, less text
and numbers, better font, scrolling where needed, make it clear what each
power-up does." Every menu and HUD is now built from one kit:

- **`Client/UI/Theme.luau`** — palette (deep-water navy surfaces, sea-foam
  `accent`, driftwood `wood`/`woodDark` headers, `sand`, coin `gold`,
  `ember`, `violet`), fonts (**FredokaOne** for titles / tabs / buttons /
  tokens, GothamMedium / GothamBold body), `Radius`, `Size`. Old keys kept
  (the minigame UIs and banners read them unchanged).
- **`Client/UI/Kit.luau`** — primitives (`corner/stroke/gradient/padding/
  listLayout/frame/label/paragraph/section/divider/keyCap`), **tiles**
  (`Kit.tile`: a gradient square carrying an image or a short token —
  `Kit.monogram(name)` when a row has no `icon`; every "icon" in the game
  is one of these until art is uploaded), rarity `gem`/`rarityLine`,
  `button` (styles primary/success/danger/gold/secondary/ghost, hover
  tweens, `enabled` attribute, `setButton` to restyle), `closeButton`,
  **`modal`** (backdrop + window + driftwood header with title tile /
  subtitle / close; returns `{gui, backdrop, window, header, title,
  subtitle, close, body}`), **`tabs`** (pill tabs with token tiles;
  `handle.set(kind)`), **`scroll`** (styled ScrollingFrame, auto canvas,
  grid or list), **`card`** (grid item: gem + tile + name + count pill +
  "in hand" ring + locked veil; handle `setSelected/setTag/setCount/
  setEquipped`), `pips` (a stat as five dots), `chip` (token tile + one
  line), `abilityCard`, `requirement` (recipe row with a have/need bar),
  `panel`.
- **`Client/UI/Describe.luau`** — data → what's shown. `perk(perk)` picks a
  token/colour from the perk's keys and shows `perk.name` + `description`
  verbatim; `perkFacts` adds short chips for the concrete bits (cast range,
  rarity floor, what it calls, free misses…). `baitEffects(effect)` renders
  **only the wired effects** — `luck`, `rewardMult`, `stun`, `hostileOnly`,
  `guaranteedDrop`, `summonsBoss` (+ "Used up on the summon") — and
  deliberately NOT `lootLuck` / `calls` / `hard` / `double` (declared in
  Bait.luau, read by nothing yet; 2f/2b will say when they go live — add a
  line then). `rodPips` / `weaponPips` scale stats across the rods/weapons
  that exist so nothing is a raw multiplier on screen.
- **`Client/UI/ItemDetail.luau`** — the shared right-hand column of the
  inventory and crafting menus: hero (tile, name in rarity colour, gem
  line, IN HAND / SELECTED / OWNED / CRAFTABLE pill, count), description,
  ABILITY card + fact chips, STATS pips, EFFECTS chips, a caller `extra`
  section (the recipe), all scrolling; 1–2 action buttons pinned below
  with a status line. `detail:show(spec)` / `clear(text)` / `setStatus`.
- **Screens on it:** InventoryController (Rods / Materials / Weapons /
  Bait), CraftingController (Rods / Weapons / Bait; locked items veiled "?"
  with their level tag; Craft enabled live off the recipe), IslandsController
  (island cards with gradient art tiles, level chip, "Beat Brinejaw first"
  guard chip, "Home of Brinejaw" chip, Travel always visible except YOU ARE
  HERE), AdminController (floating driftwood panels + scrolling pickers),
  MenuButtonsController (BAG / ANVIL / MAP / P tiles with key caps, ALT
  hint), BaitController ("ON THE HOOK" chip with tile, count pill, Q cap),
  PlayerHudController (HP tile + gradient bar that turns gold/red, heart
  jolt on hit). Every controller's state, remotes, hotkeys and exported
  `setOpen/isOpen` are unchanged from before the overhaul.
- **Not touched:** the reel / tap / snap minigame UIs, the fishing grade
  banner, the reward pops, the boss HUD and the level-up banner — they pick
  up the new fonts and colours through Theme only.

### Audio and VFX libraries

- `src/Client/Modules/Vfx.luau`: `splash`, `ring`/`ripples` (an expanding
  dashed ring of 12 tiny parts), `puff`, `burst`, `trail`, `drip` — all
  built-in `rbxasset://textures/particles/*`, parts under
  `Workspace.ClientVfx`. `CreatureVfxController` fires breach/land/flop
  splashes or sand puffs off the creature attributes (water vs ground by a
  raycast hitting `World.OCEAN_NAME`), with a second flop cue
  `FLOP_LAND_DELAY` after the hop starts.
- `src/Client/Modules/Sfx.luau`: one `CATALOGUE` of named cues (id, volume,
  pitch, wobble, 3D range) and `Sfx.play(name, position?)`; everything is a
  Roblox built-in `rbxasset://sounds/*` placeholder — swap an `id` for an
  `rbxassetid://` when real audio exists. If a built-in path is gone from the
  client it plays silence with a warning. New cues go in that one table.

## Design decisions (binding — don't reopen without the user)

- **Fishing and collection are the primary axis** (2026-08-22 pivot).
  Combat exists to make a catch feel earned, not as a deep system.
- **No `splat.wav` anywhere, and creatures on the water are silent**
  (user, 2026-08-22: "it doesn't sound good… you don't need sfx for the
  fish on the water"). The `Sfx` catalogue has no `breach` / `landWater` /
  `flopWater` cues any more — `CreatureVfxController.impact` plays a sound
  only on sand/dock; on water it's the splash VFX alone. The cod's spit and
  every boss attack got dry, heavy layers of the proven built-ins instead
  (`spitLaunch` = a short swim-stroke heave, `spitSplashGround` = a thud;
  boss: `bossSpit` / `bossSpine` / `bossSpineHit` / `bossGlobThud`, each
  attack its own voice). The only water sounds left are the bobber plop /
  reel tug and the boss's rise and fall (`impact_water`, pitched right
  down) — if those are the next complaint, they're one `id` each.
- **OVERTURNED 2026-08-24 (user), SHIPPED 2026-08-25: ranged weapons are
  live.** This bullet used to read "no guns or ranged weapons, ever"; the
  user explicitly reversed it for the 7-island progression revamp
  (`docs/revamp-plan.md`), and revamp Session 2 built the engine: a Weapons
  row with a `ranged` block shoots (CombatService's shot pipeline — hitscan
  at fire time, damage after distance/projectileSpeed, token-bucket rate
  limit + server magazine/reload; ShotAim validates the ray; RangedController
  / RangedFxController client-side). Fantasy tier on the swamp (Bogwood Bow /
  Gatorjaw Crossbow / Mire Flintlock), full-auto from the volcano on
  (Cinderlock Carbine / Basalt Scattergun / Vulkan Repeater). The `flyer` +
  `skythief` archetypes shipped alongside (grounded recovery after each dive
  is the melee counterplay; the skythief steals your resting catch).
- **Every catch is fought and killed.** No auto-collect tier.
- **A landed catch is thrown at the player by physics** and lands inland
  behind them. A scoped exception to "no physics on creatures".
- **The game is first person.** Hands are **block Roblox limbs** in the
  player's skin colour. **No prompts.** Buttons were "none" until
  2026-08-22, when the user asked for the bottom-left menu buttons (Bag /
  Craft / Admin) — keys still work for everything; ALT frees the cursor to
  click them.
- **Reel quality sets the combat opening** (Hooked → stunned, Enraged →
  harder and worth 1.5×). `Tuning.Grade` is consumed by health, reward and
  material multipliers; the stun/tell itself is not built.
- **A finished cast never fails, but an abandoned one pays nothing** (amended
  2026-08-22 by the user; the plan's original "a cast never fails" is
  struck). Misses shrink zones / cost grade, never the catch — but putting
  the rod away, swapping rods, losing the character, or idling past the
  timeout cancels the cast outright: no fish, no materials. AFK casting
  can't farm.
- **Client predicts, server owns truth** (cast swing on click, local reel
  grading, viewmodel punches; server seeds, grades, damages, grants).
- **Content is data**: rods, creatures, species shapes, materials, clips are
  rows / parameter tables, not code paths.
- Animations are **Blender-authored clips exported as Luau data**, not
  Roblox Animation assets (the viewmodel has no rig to animate).
- Touch is nominally first-class (≥64 px targets). The menu buttons let
  touch open the inventory / crafting / admin panel; it still cannot cast
  or swap hands (no buttons for those). Known; not yet asked for.

## Gotchas (tell the user — they'll hit them again)

- **Raycasts test a MeshPart's COLLISION geometry, not its render mesh
  (2026-08-23).** With the Default (convex hull) CollisionFidelity the
  volcano's crater is capped by an invisible floor at rim height: the
  player walks out over the lava on it, AND every server probe (the rim
  sampler, ground probes, CastAim) sees that cap. `sampleRim` now anchors
  the inner wall to the **lava part's shore + `rim.cliff`** (its flat disc
  hull is trustworthy) and warns with the PreciseConvexDecomposition
  instruction when it detects the cap; the cap itself only goes away in
  Studio. Same root as "teleport drops through the mountain".
- **Throws uphill need a full arc.** `launchVelocity` gave a catch thrown
  35 studs up out of the lake only `delta.Y + 2` of apex — it peaked two
  studs over the rim and clipped the cliff. Now `delta.Y + THROW_APEX`.
  And the aim ray hops past `*Dock*` parts (the pier blocks a ray at lava
  33 studs below it; the tropical dock never did at a 2-stud drop).
- **An imported MeshPart's CFrame axes tell you NOTHING about the mesh's
  orientation (2026-08-23).** Roblox's glTF importer bakes the rotation into
  the mesh geometry and leaves the part at identity rotation, so
  `part.CFrame.LookVector` is just world -Z. Two rounds of the pier-railing
  bug were spent building along world Z while the pier runs at -120 deg.
  **To get a mesh feature's direction, measure it**: probe a grid of
  down-rays over it and take the principal axis of the hits (`sxx/sxz/szz`
  covariance, `theta = 0.5 * atan2(2*sxz, sxx - szz)`) - `buildPierRailings`
  does exactly this and agrees with the .glb's own PCA to 0.01 deg.
- **A part's `Position` is its bounding-box centre, which is not the
  feature's centre.** `Volcano_Lava`'s Position is **83 studs** off the true
  crater centre (its two outflow fans drag the box) and `Volcano_Base`'s is
  ~12 off, which is why `placeIsland` anchoring on either put the whole rim
  ring off and every "corridor out from the centre" test missed the pier.
  The crater's true centre is the **centroid of the sampled inner-rim
  points** (`buildBounds` re-samples around it). And **the pier is not
  radial** about that centre at all: its axis line passes ~26 studs to one
  side, sweeping ~4.6 deg as seen from it - so anything treating the deck as
  a radial corridor (the old `clampToBounds` pier test) is tens of studs out
  at the ends. Use the measured `pier.rimEndPoint / farEndPoint / axis`.
- **Never write a `.luau` file from PowerShell (2026-08-23).**
  `Set-Content` / `Out-File` / `>` default to UTF-8-**with-BOM** (or ANSI)
  in this environment, and Luau rejects a BOM outright:
  `Expected identifier when parsing expression, got Unicode character
  U+feff` at line 1. It happened to `Shared/Data/Creatures.luau` and took
  BOTH boots down (CreatureService on the server, AdminController on the
  client) - the whole game rendered nothing, from three invisible bytes.
  stylua, selene AND `rojo build` all pass a BOM'd file, so nothing catches
  it before Play. Use the Write/Edit tools, or
  `[System.IO.File]::WriteAllText($p, $t, [System.Text.UTF8Encoding]::new($false))`.
  To find and strip them: read the bytes and check for `EF BB BF`.
- **Bulk find/replace matches literals, not the rows you meant (2026-08-23).**
  Re-colouring the seven volcano fish by replacing `Color3.fromRGB(a, b, c)`
  values silently recoloured the **Roe Hatchling** too: its `finColor` happened
  to be the exact literal the Magma Guppy's `markColor` was being changed FROM.
  Nothing flagged it - it lints, builds and boots; it is simply the wrong
  colour on a row nobody was touching. Same batch as the BOM bullet above,
  same root cause: reaching for a whole-file rewrite instead of targeted edits.
  If a bulk pass is genuinely warranted, count the occurrences of every literal
  FIRST (a value appearing twice means two rows share it) and edit anything
  ambiguous by hand.
- **When a fix "doesn't work" three times running, check that the game is
  running your code.** Three rounds of the pier wall were re-tested against a
  stale script because `rojo serve` wasn't running - the giveaway was Output
  line numbers and counts identical to the byte across separate runs, and new
  `print`s never appearing. `rojo build --output build/RobloxGame-current.rbxl`
  produces a plugin-free place file to open directly when the sync is in
  doubt.

- **The volcano's rim walls and the lava-fishing change (2026-08-23).**
  The rim is walled invisibly at boot by SAMPLING the placed mesh
  (`WorldService` "Island bounds": a polar grid of down-probes against the
  `*_Base` parts only, `Islands.items.volcano.rim` knobs). Three things
  follow: (1) if Output says `found rim ground at only N of 180 angles - no
  bounds built`, the Volcano mesh isn't placed / isn't at scale / has no
  flat ring near y 200 — no walls, no creature clamp, nothing else breaks;
  (2) the walls are `CanQuery = false` so every raycast (CastAim, creature
  grounding, the under-map net) ignores them — a new probe that should
  *see* them must opt in; (3) the pier has **no railings** (user, 2026-08-23:
  no barrier on the dock or sticking out of it onto the rim), and the inner
  wall's mouth is found **geometrically** — an inner-wall point is dropped
  when a down-probe at it, or 8 studs to either side, lands on any `*Dock*`
  part — after two axis-based tests (angular, then perpendicular distance)
  both left a wall across the deck. 9b found the island had been anchored
  ~14 studs off the true crater centre (the lopsided skirt skews the base's
  bbox); `placeIsland` now anchors on the `_Lava` disc, which is what made
  the axis maths wrong. The boot print reports how many inner-wall segments
  opened over the dock, or "(no dock parts in this pack)". Lava is fishable
  because `Volcano_Lava` is in `World.FISHABLE_NAMES` — a landing point now
  carries its surface's Y and nothing downstream may assume `WATER_Y`.

- **"Teleport to the volcano drops me through the mountain and sends me
  home" (2026-08-22).** Two things stacked: `teleportToIsland` pivoted the
  character to the hand-typed `Islands.spawn.Y` (stale the moment the mesh
  was regenerated/shrunk, and inside the rock), and the under-map net in
  `WorldService.start` always lifted you to the STARTER's `safeSpawn`. Now
  `islandSpawnPoint(entry)` probes the real ground at the spawn X/Z from
  `spawn.Y + 300` (`groundHeightAt` takes a `fromY`; the default 200 was
  level with the rim) and the net's `recoveryPoint` returns you to the
  nearest placed island's spawn — falling back to the starter only if that
  island has nothing standable. A warning names the island if the probe
  finds nothing: that means the mesh has no collision at that spot — set
  **CollisionFidelity = PreciseConvexDecomposition** on the Volcano parts in
  Studio and re-export `Assets.rbxm` (with the Default hull the crater is a
  solid plug and the rim is wherever the hull says).

- **A boss is "untargetable" while it dives, and `CreatureService.damage`
  refuses untargetable creatures** — so nothing (not an explosion) hurts it
  underwater unless that caller opts in via
  `damage(..., { ignoreUntargetable = true })`. Exactly one thing does: the
  Drowncleaver's **Brine Rot** poison, deliberately, so there is a way to
  keep damaging a boss mid-dive (see Gear perks). `inRange` also skips
  untargetable creatures, so swings retarget to the nearest minion. Also the
  despawn timer only refreshes in `damage()`, which is why the boss updater
  touches `lastFoughtAt` itself every frame (and the LINGER branch skips
  `row.boss`) — a boss that could go 30 s untargetable would otherwise
  vanish mid-fight.
- **The boss arena sits just past the round deck at the dock's end**
  (`Bosses.arena.offset` z 208 from the island origin, radius 24; deck rim
  at z ≈ 198). Move the deck (`World.ARENA_*` / `island_gen.py`) and the
  boss rises in the wrong place — keep the two in step.


- **Concurrent sessions.** At least **three** Claude sessions edited this
  project at once on 2026-08-22 (this one on fishing / viewmodels / species;
  `roblox-game-2f` on creature physics, combat, pufferfish, player health;
  `roblox-game-80` on crafting materials). Files were clobbered twice
  (`CombatController.luau` and `Sfx.luau`, each reconstructed against the
  surviving contract), and this doc's rewrite collided twice. Before
  editing, `ListAgents` for live peers and claim the file by message;
  prefer small `Edit`s over whole-file `Write`s on shared files; read right
  before editing; after a rewrite, tell the peers.
- **Never leave an offset on `camera.CFrame` across frames.** Roblox's
  default camera derives each frame's look direction from the camera's
  *current* CFrame, so any rotation applied after the camera scripts
  (RenderPriority.Camera) is absorbed into the look and the next frame's
  offset stacks on it — the hit nod in `CombatVfxController` walked the view
  downward on every hit (bug fixed 2026-08-22). The pattern: apply the
  effect at `Camera + 1`, remember it, and undo it at `Camera − 1` before
  the camera scripts run (`restoreCamera` / `applyShake`). Any future
  camera shake / recoil / bob must do the same.
- `rojo serve` reads `default.project.json` once — restart it after any
  project-file change, and after replacing `Assets.rbxm` (it doesn't watch
  rbxm reliably).
- Connecting the Rojo plugin during Play fails ("Http requests can only be
  executed by game server"). Connect in edit mode.
- **Studio's Play camera hard-captures `I`/`O` for zoom** below where CAS
  priority can override it (devforum-confirmed; works in a live game). The
  inventory binds **both `I` and `B`** for that reason. If another hotkey
  hits it, give it a second non-reserved key — don't fight it with priority.
  (`Tab` is the CoreGui player list; user scripts can't sink it.)
- The client boot `require`s every controller up front: one broken module
  (or the client `Remotes` module waiting on a remote the *server* never
  created because the server boot died) stops all of them. Check Output for
  `[Boot]`. A regression to third person is the usual symptom. **It has
  happened twice on 2026-08-22** — once from a runtime `CollisionFidelity`
  write (server), once from an `ORDER` entry (`BaitController`) whose module
  file didn't exist yet (client: the `assert` fires before *any* controller
  runs). Rule: add a name to `ORDER` only in the same edit as the module
  file, and never leave a half-landed feature's name in the list. Nothing in
  stylua/selene/rojo catches either; a quick check is "every `ORDER` name
  has a `.luau` in its folder".
- **Blender → Roblox axis mapping is not fully pinned down.** The glTF
  importer appears to rotate meshes 180° about Y (Blender −y → Roblox −Z
  forward; +x → −X) — inferred from one screenshot of the rod tackle, not
  measured. Consequences: the rod's line is tilted toward Blender −y; the
  fish no longer care (bounding-box orientation); the dock note ("Blender
  270° = Roblox +Z") and `World.DOCK_START_Z` may be on the wrong sign.
  **Verify once in Studio** (read `Dock_Planks`' Position.Z) before relying
  on any authored direction. The animation clips are unaffected — their axis
  maths is done in Python and never passes through the importer.
- Blender headless quirks: `Image.save()` and `render.filepath` resolve
  relative paths against Blender's own directory, silently writing nowhere
  — always `os.path.abspath`. Workbench renders the material's *viewport*
  colour (`diffuse_color`), not the node colour. There is no system Python;
  all generators run under Blender's.
- Studio serialises `CollisionFidelity` inside `PhysicalConfigData`, so it
  can't be checked from the build XML — verify the arch/dock collision in
  Studio if walking feels wrong. **Never write `CollisionFidelity` from a
  script** (2026-08-22 incident): it's a Plugin-capability property, the
  write throws "lacking capability Plugin", and because the boot is
  fail-fast that one line in `WorldService.init` took down every service
  after it — island, rod, fishing, combat, creatures — while stylua/selene/
  rojo all stayed green. The symptom was "the island disappeared and the
  rod is gone". If the game comes up empty, read Output for `[Boot]` first.
- Mesh ids inside `Assets.rbxm` belong to the user's account; they load for
  that account on any machine, not for other accounts.

## Architecture conventions (established — don't deviate without reason)

- **Service/controller pattern, no framework.** `src/Server/Services/*`
  and `src/Client/Controllers/*` are plain tables with optional `init()`
  (build, bind remotes; must not assume later modules are running) and
  `start()` (loops, existing players). `init.server.luau` /
  `init.client.luau` own an explicit `ORDER`; a module may require anything
  above it. Current orders are in those files and are load-bearing (e.g.
  `PlayerService` before `CreatureService`, `MaterialService` before
  `FishingService`).
- **Shared constants live in `src/Shared/Config/`** (`World`, `Ocean`,
  `Equipment`, `Tuning` — every balance number), never duplicated.
- **Content is rows in `src/Shared/Data/`** (`Rods`, `Weapons`, `Creatures`,
  `Materials`, and the generated clips `RodCastAnim` / `FistPunchAnim` /
  `WeaponSwingAnim`).
- **Network surface is declared once** in `src/Shared/Net/Remotes.luau`
  (`DEFS`); never `Instance.new` a remote elsewhere. Prefer **replicated
  attributes** for scalar state (Equipped, creature Health, Player
  progression), the inventory's pull-then-push remote pair for table state
  (items, materials), and one-shot remotes only for moments.
- **No `Humanoid` on any creature; one Heartbeat for all of them.** The
  player's own Humanoid is fine.
- **Imported meshes are recoloured by part name in code**; part names are
  the contract (`MESH_COLOR`, `RodModel.PART_COLOR`, `Fish_*`).
- Client feedback systems are **attribute-driven and decoupled** from their
  source (hit feedback off `Health`, creature VFX off `Thrown/Landed/Flops`,
  HUDs off Player/Humanoid attributes) so a new damage source or creature
  needs no feedback wiring. Server payouts hang off one
  `CreatureService.Killed` event the same way.
- Shared UI look is `src/Client/UI/Theme.luau`; layout knobs are constants
  at the top of each controller. HUD real estate: bottom-right progression
  (+ the reward / material pop stack rising out of it), top-centre banners,
  top-right health, bottom-centre reel bar; material counts live inside the
  inventory modal, not on the HUD.
- Pure rendering modules (`ReelBar`) are split from logic (`FishingController`).

## Asset pipelines (summary — `assets/README.md` has the full walkthroughs)

Everything visual is generated by a Blender 4.5 Python script run headless
(`%LOCALAPPDATA%\Programs\blender-4.5.12-windows-x64\blender.exe
--background --python-exit-code 1 --python assets\<script>.py -- <out>`):

| Script | Output | Runtime consumer | Import step |
|---|---|---|---|
| `island_gen.py` | `island.glb` | `WorldService` (`Assets/Island`) | Import, set `PreciseConvexDecomposition` on the solid parts |
| `rod_gen.py` | `rod.glb` (+ `rod_preview.png`) | `RodModel` (`Assets/RodPack`) | Import |
| `fish_gen.py` | `fish.glb` (+ `fish_preview.png`) | `CreatureModel` (`Assets/FishPack`) | Import |
| `creatures_gen.py` | `creatures.glb` (+ `creatures_preview.png`) — 11 species | `CreatureModel` species (`Assets/CreaturePack`) | Import (re-import pending for the 8 enemies) |
| `weapon_gen.py` | `weapon.glb` (+ `weapon_preview.png`) | `WeaponModel` variants (`Assets/WeaponPack`) | Import (pending) |
| `water_gen.py` | `water.png` | `Ocean.TEXTURE_ID` | Upload via Asset Manager, paste id |
| `rod_cast_anim.py` | `Shared/Data/RodCastAnim.luau` + `rod_cast.blend` | `RodViewmodelController` | none (Rojo) |
| `fist_punch_anim.py` | `Shared/Data/FistPunchAnim.luau` + `fist_punch.blend` | `FistsViewmodelController` | none (Rojo) |
| `weapon_swing_anim.py` | `Shared/Data/WeaponSwingAnim.luau` + `weapon_swing.blend` | `WeaponViewmodelController` | none (Rojo) |

All four crafted weapons (DriftwoodClub, Scaleblade, Shellcrusher,
Drowncleaver) are variants in the Blender **WeaponPack** (`weapon_gen.py`),
assembled by `WeaponModel.assembleVariant` like rods. `WeaponModel` still
carries the procedural `club`/`blade` builders (`model.shape`) as the
**pre-import fallback**, so a weapon is never invisible before the import.

Meshes must be glTF (`.glb`), never OBJ (OBJ merges everything into one
part and drops materials). After any mesh import, right-click the **`Assets`
folder** → Save to File → overwrite `assets/Assets.rbxm` (selecting the
models instead produces a multi-root file Rojo rejects), then restart `rojo
serve`. Nothing warns when the rbxm is stale relative to a `.glb` — compare
dates. Every consumer falls back to a stand-in with a `warn()` that prints
the import steps, so the game always boots.

## File map

```
default.project.json        Shared/Server/Client mappings, Assets.rbxm → ReplicatedStorage.Assets,
                            StarterPlayer first-person properties
src/
  Shared/
    Config/
      World.luau            island/dock geometry, WATER_Y, spawn probe, OCEAN_NAME; ARENA_* unused
      Ocean.luau            water colour, texture id, LAYERS
      Equipment.luau        loadout kinds (rod | weapon) + the Equipped / EquippedRodId / EquippedWeaponId attribute names
      Tuning.luau           Reel, Cast, Rarity, Creature (throw/flop/rush/contact), Player, Combat,
                            Rewards, Progression, Grade, Materials
    Data/
      Rods.luau             rod rows (stats, model/grip/length, reel block, optional craft recipe)
      Creatures.luau        21 rows (9 fish as `flopper`, puffer + crab `rusher`, 2 drowned `shambler`, 8 enemies-slice hostiles:
                            tideline_skipper/gullet_cod/tidebomb_urchin/moonbell_jelly/sand_lurker/pearl_mimic/pickpocket_hermit/voltray,
                            + brinejaw the island boss, rarity "Boss"); rarity/archetype/stance/shape/drops/boss, byRarity index
      Bosses.luau           island bosses: gate (level + rod + weapon), arena, phases + the attack book; Bosses.byIsland
      Materials.luau        6 crafting-material rows (tier basic|rare, rarity, icon, colour) + Materials.order; +barnacle_chitin, cursed_bone (creature drops)
      Weapons.luau          melee weapon rows: fists (refs Tuning.Combat), driftwood_club, scale_blade
                            (damage/cooldown/reach/knockback, swing clip name, procedural model block, recipe)
      RodCastAnim.luau      GENERATED cast clip
      FistPunchAnim.luau    GENERATED punch clips (jab/cross, track per fist)
      WeaponSwingAnim.luau  GENERATED weapon swing clips (chop/slash + hack/thrust/smash/sweep/flourish/pummel), whole-viewmodel transform about the elbow
      GunReloadAnim.luau    GENERATED per-gun multi-track reload clips (weapon/mag/action/hand tracks) - see "The post-ship days"
    Net/
      Remotes.luau          GetInventory, InventoryUpdated, RequestCast, CastAccepted, CastRejected,
                            SubmitReelClick, ReelRoundResult, CastResolved, AbandonCast, RequestEquip,
                            RequestAttack, CreatureHit, RewardGranted, GetMaterials, MaterialsUpdated,
                            MaterialGranted, RequestCraft, CraftResult, RequestEquipRod, RequestEquipWeapon,
                            AdminGrant, ItemDropped, CreatureEvent (kind, position, extra)
    Modules/
      Rng.luau              deterministic xorshift streams (lifted from backup)
      ReelMath.luau         marker/zone/scoring math shared by both sides (bullseye zones)
      CastAim.luau          aim ray + water/range rules
      RodModel.luau         rod Model from a row: pick variant out of RodPack, per-rod recolour, tackle toggle, HOLD_OFFSET
      CreatureModel.luau    species assembly from FishPack + CreaturePack / procedural fallback parts (BUILDERS by body.shape: puffer/crab/zombie
                            + skipper/gulletcod/urchin/jelly/lurker/mimic/hermit/ray/leviathan) / stand-in, recolour, welds
      WeaponModel.luau      weapon Model from a row: WeaponPack mesh variant (assembleVariant, Weapon_* + glow/neon) else club/blade procedural builders; Weapon_Grip contract, HOLD_OFFSET
      Progression.luau      level curve + attribute names
  Server/
    init.server.luau        ORDER: World, Inventory, Player, Rod, Weapon, Creature, Material, Bait, Fishing, Combat,
                            Progression, Crafting, Boss, Admin, Drop
    Services/
      WorldService.luau     ocean + texture layers, island mesh, spawn, template cleanup
      InventoryService.luau mixed rod+weapon ownership (grantItem/ownsItem), equipped rod + weapon
                            (setEquippedRod/setEquippedWeapon → EquippedRodId/EquippedWeaponId), onEquipChanged
      PlayerService.luau    player health on the Humanoid: damage(), i-frame, regen
      RodService.luau       welds/removes the world rod per loadout
      WeaponService.luau    welds/removes the world weapon per loadout (only rows with a model)
      CreatureService.luau  flat array + one Heartbeat: spawn (+extra → Killed), throw, flop, 11 archetype updaters (ARCHETYPE_UPDATERS incl. boss:
                            BOSS_ATTACKS handlers, phases, enrage, globs list), upright stance, damage/untargetable/hitModifiers/participants,
                            knockback + juggle, spit timers, explosions, CreatureEvent moments
      BossService.luau      raises each island's boss for a qualifying player (level + owns rod + weapon, on the island), pays participants,
                            sets Cleared_<islandId>, fires bossDown
      MaterialService.luau  per-player material counts; grantCast on resolve, rare drops off Killed (per-creature drops.materials override)
      FishingService.luau   cast validation, seeded reel grading, creature roll + spawn, material grant
      CombatService.luau    RequestAttack → equipped Weapons row → nearest creature in reach → hitModifiers (exposed ×2 / charging shock) → damage/knockback/CreatureHit
      ProgressionService.luau  coins/XP/levels off Killed; Player attributes; RewardGranted
      CraftingService.luau  RequestCraft (rod / weapon / bait / boat id) → validate level/coins/mats/hearts → spend + grant → CraftResult
      DropService.luau      third Killed listener: rolls a creature row's drops.items → grantItem + ItemDropped (skips suppressDrops)
      BoatService.luau      (S3) boat tiers off Heart_brinejaw + crafting, summon/park/sink, driver network ownership, seaworthiness DoT
      SpawnerService.luau   (S3) ambient island hostiles off Islands ambient blocks; setBias/clearBias event hook; groundPointNear/playersOn helpers
      RaidService.luau      (S3) wave raids off Islands raid blocks; noLinger mobs, participants payout, RaidState broadcast
      WeatherService.luau   (S3/S4) timed weather windows (ice blizzard) on WorldEvent + spawner flyer bias
      EruptionService.luau  (S3) volcano lava-bomb windows: telegraph/spit/explode vocabulary + Hazards damage
    Modules/
      Hazards.luau          (S3) fireEvent + damagePlayersInRadius, the one AoE rule (CreatureService delegates)
  Client/
    init.client.luau        ORDER: Camera, RodViewmodel, FistsViewmodel, WeaponViewmodel, Inventory, Crafting,
                            Fishing, Ocean, Lava, CreatureVfx, Equip, Combat, Ranged, RangedFx, CombatFeedback,
                            CombatVfx, Progression, PlayerHud, Admin, Islands, Trophy, Boat, Drop, Bait,
                            MenuButtons, CreatureEvent, BossHud, RaidHud, Weather
    Controllers/
      CameraController.luau        first-person lock, cursor free/lock for menus
      RodViewmodelController.luau  rod rig, tip tracking, cast clip playback
      FistsViewmodelController.luau both block arms, punch clips, stretching forearm, knuckle trail
      WeaponViewmodelController.luau crafted weapon + right arm rig, swing clips about the elbow, weapon trail
      InventoryController.luau     I/B modal: Rods/Materials/Weapons tabs + card grid + detail panel
      CraftingController.luau      C modal: Rods/Weapons tabs + recipe/craft/equip detail (mats+coins+level gated)
      FishingController.luau       right-click cast, bobber arc + line, reel bar, banners, VFX/SFX hooks
      OceanController.luau         scrolls the water texture + drives the tide (water plane + foam rim rise/fall)
      CreatureVfxController.luau   breach/land/flop effects off creature attributes
      CreatureEventController.luau enemy states off Dashing/Exposed/Buried/Open/Charging/Enraged attrs + moments off CreatureEvent (spit glob, explosion, emerge, snap, steal, pulse,
                                   + the boss's bossRise/telegraph/bossSnap/sweep/slam/pull (VectorForce on the local root)/spine/spineHit/summon/bossDive/enrage/bossDown)
      BossHudController.luau       top-centre boss name + health bar off BossName/Health/Enraged; rise/CLEARED/EXPOSED/REGROW/finale cards off CreatureEvent
      TrophyController.luau        (S4) H / HALL button: the Trophy Hall - one card per boss in saga order off the Heart_* attributes
      TrophyShelfController.luau   (S4) decorates any boat's TrophyShelf HeartMount1..6 with the owner's heart orbs (OwnerUserId attr)
      WeatherController.luau       (S4) ice blizzard fog/snow off WorldEvent + the gloom island's perpetual dark / personal lamp (lantern rods double it)
      BoatController.luau          (S3) R/touch-button summon; drives the owner's hull (Boat_Move/Boat_Align, Y held at WATER_Y); BoatMessage banners
      RaidHudController.luau       (S3) raid countdown/wave/remaining line + cards off RaidState, filtered to the local island (Islands.islandAt)
      EquipController.luau         1 (rod) / 2 (weapon) hotkeys → RequestEquip
      CombatController.luau        click → punch or weapon swing clip (per equipped row) → RequestAttack at HIT_TIME
      CombatFeedbackController.luau health bar, tint flash, damage numbers off Health
      CombatVfxController.luau     impact burst, camera shake/nod, hit SFX off CreatureHit
      ProgressionController.luau   top-left level/XP/coins HUD, reward pop, level banner
      PlayerHudController.luau     top-right minimal health pill + damage flash
      DropController.luau          centre "You found: X!" banner off the ItemDropped remote
      MenuButtonsController.luau   bottom-left Bag / Craft / Admin buttons (setOpen/isOpen of each menu), ALT frees the cursor
    Modules/
      Viewmodel.luau        camera pin (sway/bob/breathe), Rig, block arms, placeArm, clips, watchArms
      Vfx.luau              low-poly particle helpers
      Sfx.luau              sound catalogue + play()
    UI/
      Theme.luau            palette (navy / sea-foam / driftwood / sand / gold), FredokaOne + Gotham fonts, Radius, Size, MIN_TAP
      Kit.luau              shared UI parts: modal shell, tabs, scroll, card, tile/monogram, gem, button, pips, chip, abilityCard, requirement
      Describe.luau         data -> display: perk token/colour + facts, WIRED bait effects only, rod/weapon stat pips
      ItemDetail.luau       the inventory/crafting detail column (hero, ability, stats, effects, recipe slot, actions)
      ReelBar.luau          the reel bar rendering
assets/
  Assets.rbxm               Studio export of ReplicatedStorage/Assets (Island, RodPack, FishPack; CreaturePack + WeaponPack pending import)
  island_gen.py / island.glb
  rod_gen.py / rod.glb        (RodPack: Twig/Bamboo/Angler/Abyssal variants)
  fish_gen.py / fish.glb / fish_preview.png
  creatures_gen.py / creatures.glb / creatures_preview.png  (CreaturePack: Crab/Deckhand/Angler + Skipper/GulletCod/Urchin/Jelly/Lurker/Mimic/Hermit/Voltray + Leviathan (boss); re-import pending)
  weapon_gen.py / weapon.glb / weapon_preview.png  (WeaponPack: DriftwoodClub/Scaleblade/Shellcrusher/Drowncleaver; import pending)
  water_gen.py / water.png
  rod_cast_anim.py / rod_cast.blend
  fist_punch_anim.py / fist_punch.blend
  weapon_swing_anim.py / weapon_swing.blend
  README.md                 full pipeline + import walkthroughs
```

## Tooling / verification (run every slice, no exceptions)

The pre-commit gate (2026-08-25, revamp sessions — run ALL FOUR before every
commit; the morning session inherits this bar):

```bash
stylua src                        # format — must exit 0
selene src                        # lint — must be 0 errors, 0 warnings, 0 parse errors
rojo build -o /tmp/check.rbxlx    # structural validation — must exit 0
python3 tools/check_content.py    # cross-file content invariants — must exit 0
```

`tools/check_content.py` catches the integration bug class that actually
bites with four sessions writing the data tables at once: an id referenced
in one file that doesn't exist in another (recipe materials, boss ids,
brood/roster rows, orders, waters keys, requiresHearts...). A useful fifth
check when touching a boot ORDER: every name listed in
`init.server.luau`/`init.client.luau` must have its module file, or the
whole boot dies (see Gotchas).

`stylua.toml` / `selene.toml` are at the project root; `aftman.toml` pins
`rojo`, `StyLua`, `selene`. Rojo does not parse Luau — a syntax error can
pass `rojo build` — so always run all three. Generated clip modules are
written stylua-clean so regeneration never churns formatting. Git IS live on
this machine (macOS, 2026-08-25): commit per milestone with explicit paths
(`git add <files>` — never `-A`, several sessions share the one checkout).
The pre-reset build was mined on the old Windows machine; its path there
(`C:\Users\sreen\Desktop\Roblox Game (pre-reset backup)\`) is stale here.

## Known gaps / next steps (not yet asked for — don't start unprompted)

- **Crafting Slice 2 — now BUILT** for rods AND weapons (see the crafting
  section). Rods have distinct RodPack meshes; the crafted weapons now have
  WeaponPack meshes too (Shellcrusher/Drowncleaver, import pending). Remaining
  follow-up: none — equip-from-inventory is done (2026-08-22).
- **Persistence (Slice 9) — now BUILT (2026-08-25):** `DataService`
  (first in the boot ORDER) loads/saves a per-player profile with
  UpdateAsync session locking (stale after 90s; retry ×3 then kick),
  autosave every 60s + PlayerRemoving + BindToClose. Progression /
  Inventory / Material / Bait services each register a load/serialize
  slice; `Cleared_*` and `Heart_*` attributes ride along. Studio without
  API access falls back to in-memory with a loud warning and never saves.
- **Archetypes:** ten run (`rusher`, `shambler` + the eight enemies-slice
  ones); the real fish are `flopper` by user decision. **Enemies slice 2
  (art)** is next: CreaturePack species for the eight (the rows already
  name them; stand-ins show until then). No creature pooling. No stun/enraged tell from
  the reel grade (the multipliers apply; the visible state doesn't).
  Creatures despawn after `LINGER` (30 s) of not being fought — the timer
  resets on every hit, so nothing vanishes mid-fight (bosses never linger).
- **Bosses:** the full ladder is in — Brinejaw, Old Gnashroot, Rimefang,
  Pyrelisk, Noctyss, Admiral Wrack and the Kraken, each bait-summoned, each
  leaving its heart. Still true for all seven: attack numbers untuned, no
  death animation, no per-player "what you're missing" readout for the
  gate.
- **Weapons / targeting:** two craftable weapons exist (see Combat); more
  are a row each. Still proximity targeting — the plan's screen-space
  targeting is unbuilt. Hit VFX/SFX are shared across weapons (a heavier
  club thump / blade slice cue would be a `Sfx` catalogue entry + a branch
  in `CombatVfxController` off the attacker's weapon). Other players see
  the welded club/blade but **no swing** (same Motor6D caveat as the rod).
- **Style / juggle / launch (Slice 7)** — nothing.
- **Arena deck** — open question (see World).
- **Touch input** can open the menus (bottom-left buttons) but still cannot
  cast or swap hands (no buttons for those).
- **Other players** see a static welded rod: no cast swing, no punches, no
  hidden idle tackle during a cast.
- **Shirt sleeves** on the block arms; **icons** in the inventory; real
  audio (all cues are Roblox built-ins); a modelled pufferfish species.
- **Unreviewed in Studio:** species shapes, pufferfish/rusher, player
  health + HUD, progression HUD, the materials strip in the inventory, most
  combat VFX/SFX, the stretching-forearm punch fix, the crafting menu's
  Weapons tab, the club/blade look + hold pose + swing clips + balance.
  Expect a tuning prompt for each.
