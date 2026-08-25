# Verification audit — the 7-Island Saga revamp

Static audit of every phase's verification bullets (docs/revamp-plan.md, P0–P7),
performed at tree state **4793d70** (2026-08-25, overnight run; all four gates
green at that commit: stylua / selene 0-0-0 / rojo build / check_content 7
islands · 7 bosses · 110 creatures · 36 rods · 36 weapons · 21 baits · 32
materials). Method: trace each requirement to the code that satisfies it —
**PASS** = holds structurally, **FAIL** = the code cannot satisfy it (none
found; see note at the end), **STUDIO** = only a live playtest can tell. This
file's STUDIO bucket is the morning playtest script.

Auditor: session 5a (S3 lane). Nothing was fixed during the audit.

## P0 — Persistence

| Requirement | Verdict | Evidence |
|---|---|---|
| DataService first in boot ORDER | PASS | `init.server.luau` ORDER[1] |
| UpdateAsync session locking, stale lock takeover, retry → kick | PASS | `DataService.luau` (lock `{id, at}`, UpdateAsync claim/write paths) |
| Autosave 60s + PlayerRemoving + BindToClose | PASS | `AUTOSAVE_INTERVAL = 60`, `game:BindToClose` |
| Migrations scaffold (`version` + MIGRATIONS chain) | PASS | `CURRENT_VERSION` / `MIGRATIONS[v]` loop |
| Slices registered by owning services | PASS | `DataService.register` called from Progression / Inventory / Material / Bait services |
| `Cleared_*` / `Heart_*` / `BoatTier` restored onto attributes | PASS | DataService restores all three prefixes; `boatTier > 0` → `BoatTier` |
| Earn/spend gated until the profile loads | PASS | `DataService.isLoaded` guards in FishingService + CraftingService |
| Studio-without-API fallback, loud, never saves | PASS | in-memory fallback + warning path |
| Profile actually round-trips through a real DataStore | STUDIO | needs a published/API-enabled place |

## P0.5 — Content thinning + hearts framework

| Requirement | Verdict | Evidence |
|---|---|---|
| Per-island kit 5 rods / 5 weapons / 3 baits (starters apart) | PASS | check_content totals: 36 rods (1+5×7), 36 weapons (1+5×7), 21 baits (3×7) |
| ~4 signature materials per island, universals everywhere | PASS | 32 materials; check_content validates every recipe id |
| Hearts as `Heart_<bossId>` attributes, never spent | PASS | `BossService.heartAttribute` + `onKilled`; recipes carry `requiresHearts` (checked in CraftingService, nothing ever decrements) |
| `Recipe.requiresHearts` rendered in the crafting UI | PASS | `CraftingController.recipeSection` ("OWNED / UNDEFEATED" row) |
| Legendary tier armed (0.4) + one chase fish per island | PASS | `Tuning.Rarity.WEIGHTS.Legendary = 0.4`; 7 Legendary creature rows |
| Brinejaw gate 15 → 7 | PASS | `Bosses.luau` `gate = { level = 7 }` |
| Pyrelisk data + volcano no longer a dead end | PASS | `pyrelisk` boss row; `Islands.items.volcano.boss = "pyrelisk"` |

## P1 — Ranged core

| Requirement | Verdict | Evidence |
|---|---|---|
| `RequestShoot` / `ShotFired` remotes; melee `RequestAttack` untouched | PASS | `Remotes.luau`; CombatService line ~179 ("a gun doesn't swing") |
| `ShotAim` origin validation (ORIGIN_SLACK trust model) | PASS | `Shared/Modules/ShotAim.luau`; `ShotAim.originOk` in `onRequestShoot` |
| Hitscan at fire time, damage after distance/projectileSpeed (landAt queue) | PASS | CombatService shot queue with `landAt` clock |
| Arc weapons re-check a small sphere at landing (dodged arrow misses) | PASS | `shot.arc` → `CreatureService.inRange(shot.landing, RT.ARC_RECHECK_RADIUS)[1]` |
| Token bucket + magazine/reload server-side; swap-cycling mints nothing | PASS | per-weapon state `{shotsInMag, reloadUntil, bucket, lastRefillAt}` kept across swaps (review find already fixed) |
| Perk mapping: poison/execute/lifesteal/frenzy ranged; cleave/uproot melee-only | PASS | perk branch in CombatService (`uproot` explicitly `not ranged`) |
| Pellets (shotguns) | PASS | `for _ = 1, ranged.pellets or 1` |
| RangedController (fire modes, scoped zoom, mag/reload UI) + RangedFxController (tracer pool) | PASS | both in client ORDER; `zoomFov` → FieldOfView tween confirmed |
| Procedural "bow"/"gun" shapes in WeaponModel | PASS | `BUILDERS.bow` / `BUILDERS.gun` |
| "No guns ever" decision struck in context.md + Weapons header | PASS | both record the 2026-08-24 overturn |
| Recoil/tracer/zoom FEEL, full-auto exploit under real latency | STUDIO | needs live input |

## P2 — Flyers

| Requirement | Verdict | Evidence |
|---|---|---|
| `flyer` machine: circle → windup → dive → grounded → climb | PASS | `updateFlyerCore` (CreatureService, "flyer archetypes" section) |
| Grounded recovery = the melee window; height rides pose, `pos` ground-clamped | PASS | grounded mode flops like a catch; `flyHeight` in pose hop term |
| Dive aimed at position-at-dive-start (dodge window) + windup tell | PASS | `FLY_WINDUP` 0.7s tell; dive line locked at start |
| Knockback 0.15 / launch 0 / uproot-immune | PASS | `Tuning.Creature` tables + `UPROOT_IMMUNE = { boss, flyer, skythief }` |
| Skythief steals a resting catch, carries it out to sea, drops on kill | PASS | `updateSkythief` + `carriedBy` pre-emption in update() |
| ~8 flyer rows across islands | PASS | bog_gull, will_o_wisp (flyer), dread_dragonfly (skythief), hailfin skua, rigging wraith, stormpetrel, galestreak, etc. |
| Dive telegraph readability / dodge feel | STUDIO | timing feel |

## P3 — Swamp (Blackmire Fen)

| Requirement | Verdict | Evidence |
|---|---|---|
| Islands entry slot 2, (3000,0,0), unlock 8, boss old_gnashroot | PASS | `Islands.items.swamp` |
| Full 5/5/3 kit + 4 materials + mireheart gating | PASS | check_content (recipes, requiresHearts ids all resolve) |
| 13 creatures + Golden Gar chase + Old Gnashroot (P1→P2 murk dive/brood→P3) | PASS | Creatures/Bosses rows |
| `waters = "swamp"` via Swamp_Water surface | PASS | `World.FISHABLE_NAMES` + `WATERS_BY_PART`; FishingService filters rows by `watersOf` |
| Island mesh generated (Swamp in the 6-island pack) | PASS | `assets/island_swamp.glb` + `build_swamp_water` etc. in island_gen.py (single-generator route instead of a separate island_swamp_gen.py — same style, one pipeline) |
| Mesh IMPORT + look/walkability | STUDIO | docs/import-checklist.md |
| Interim volcano slot-3 shift | PASS (superseded) | deliberately skipped — all islands shipped straight at final positions (plan's rollout note, recommended path) |

## P4 — Spawner, raids, events

| Requirement | Verdict | Evidence |
|---|---|---|
| SpawnerService: per-island ambient rosters, ring spawns 60–100, LINGER cleanup, global cap ~40 | PASS | `SpawnerService.luau` + `Tuning.Spawner` (cap 40) |
| Shared `Islands.islandAt` helper | PASS | `Config/Islands.luau`; WorldService + RaidHud delegate to it |
| Hazards.luau extraction of damagePlayersInRadius/fireEvent | PASS | `Server/Modules/Hazards.luau`; CreatureService delegates, identical semantics |
| RaidService state machine idle→announced(45–60s)→waves→cleared/failed | PASS | `RaidService.luau` |
| Raid spawns `{raid, noLinger}`; first-class `creature.noLinger` in the despawn check | PASS | spawn copies `extra.noLinger`; despawn sweep exempts it (Kraken tentacles reuse it) |
| Participants payout on clear; reduced bounty / suppressed drops | PASS | `bounty` + `suppressDrops` ride the existing extra bag (Progression/Material read them; DropService guard added) |
| RaidState remote + RaidHudController filtered to local island | PASS | 1 Hz broadcast; client filters via islandAt |
| Blizzard: server window + WorldEvent + client fog + flyer bias ×3 | PASS | WeatherService (ice row, bias flyer/skythief ×3 through SpawnerService.setBias) + WeatherController |
| Eruption: telegraphed lava bombs (ring → 1.25s → splash) on the glob clock | PASS | EruptionService — telegraph/spit/explode client vocabulary, Hazards damage |
| Ambient + raid rosters wired: tropical / swamp / volcano (+ ice/gloom/wreck in S4) | PASS | all six Islands entries carry ambient + raid blocks |
| Raid difficulty, spawn density, eruption dodge feel, blizzard readability | STUDIO | tuning by feel |

## P5 — Boat

| Requirement | Verdict | Evidence |
|---|---|---|
| Boats.luau tiers exactly per the plan's boat table; tier 1 free on Brinejaw | PASS | 6 rows, costs verbatim; grant off Heart_brinejaw (incl. back-fill on load + present-player sweep) |
| Crafted through the item-agnostic CraftingService; ladder (next tier only) | PASS | `isBoat` branch |
| Procedural BoatModel (no import) + BoatPack mesh path + trophy shelf mounts | PASS | `BoatModel.luau` (HeartMount1..6); `assets/boat.glb` shipped |
| VehicleSeat + LinearVelocity/AlignOrientation, ownership to the driver | PASS | BoatService `SetNetworkOwner`; constraints in the collider |
| Y locked to World.WATER_Y (+ rest height + bob), never the tide plane | PASS | BoatController `restY` from the constant |
| Custom collision group vs the ocean slab (and vs creatures) | PASS | Water/Boat groups, pairs non-collidable |
| Spawn/recall to nearest shoreline; one boat per player | PASS | `boatLaunchCFrame`; summon-is-recall |
| Seaworthiness DoT past tier range, sink dumps players, no free mid-sea repair | PASS | openSeaDistance + ramping DoT; hull damage carries across summons, sink → 25% hull, shore summon repairs (review finds 13/15 fixed) |
| `WorldService.mayEnter` unifying level + Cleared_ + BoatTier; teleport menu = fast travel | PASS | one gate, both paths funnel through it |
| 0.5s containment sweep bounces trespassers (walk-on-ocean hole closed; admins exempt; SeatWeld broken first) | PASS | sweep in WorldService.start (review find 16 fixed) |
| Harbor notches in the rim walls | PASS (vacuous) | no island currently declares a `rim` block, so there are no rim walls to notch; the dormant wall builder is unchanged — re-audit if a bounded island returns |
| Drive feel (accel/turn/bob), boarding while parked, trophy shelf look | STUDIO | live feel |

## P6 — Islands 3–6 data + meshes

| Requirement | Verdict | Evidence |
|---|---|---|
| Frostmaw / Gloomtrench / Wreckwater entries at final slots + bands | PASS | Islands.items (6000/12000/15000, unlock 15/29/36) |
| Volcano final slot 4 (9000,0,0), L22–28, rewards ×6, full-auto tier | PASS | entry + re-gated rows + Cinderlock/Basalt/Vulkan at L22/25/28 |
| Full kits + bosses (Rimefang / Noctyss / Admiral Wrack) + hearts | PASS | check_content: 7 bosses, all recipe/heart ids resolve |
| Ice-hole / dark-water / bay fishing surfaces | PASS | Frostmaw_IceHoles→ice, Gloomtrench_DarkWater→gloom, Wreckwater_Bay→wreck in World.luau |
| Gloom light/lantern mechanic | PASS | WeatherController perpetual-dark branch (position-keyed, lantern-rod bonus) |
| Boarding raids (Wreckwater) + island raid rosters | PASS | raid blocks on all six entries; Wreckwater's waves are the boarding flavour |
| All four island meshes generated + previews | PASS | island_swamp/ice/gloom/wreck.glb + 6-island pack |
| Mesh IMPORTS, spawn probe heights, collision fidelity, dock walkability | STUDIO | docs/import-checklist.md — the big one |

## P7 — Hearts + finale

| Requirement | Verdict | Evidence |
|---|---|---|
| TrophyController (Trophy Hall) + boat trophy shelf off Heart_* attrs | PASS | TrophyController + TrophyShelfController (walks up to OwnerUserId, decorates HeartMount1..6), both in client ORDER |
| Maelstrom as procedural site: site=true, out of Islands.order, no mesh | PASS | entry + `buildMaelstromSite` in WorldService; loadIslands skips/places site entries; oceanSpan covers it once placed at boot |
| Hidden from travel until 6 hearts; server-side gate too | PASS | travel-menu veil (4497935) AND mayEnter's site branch (all six Heart_* + BoatTier 6 / Stormbreaker Keel) |
| Kraken's Call: L48, requires owning all six hearts — checked, never spent | PASS | bait recipe + `gate.hearts` on the kraken Bosses entry; BossService.qualifies learned the hearts gate |
| Tentacles = `parts` ring: ordinary rows, noLinger, suppressed drops, regrow 24s | PASS | Bosses.kraken `parts`; CreatureService tentacle ring + partsAlive/partsDownAt |
| rangedOnly head, vulnerableWhen="partsDown" exposure windows | PASS | melee target-pick `skipRangedOnly`; damage gate on `vulnerableWhen` |
| Flyer brood + every prior boss's signature in P3 | PASS | kraken phase tables (snap/tail/slam/volley/pull/dive/brood/spines) |
| Heart_kraken + finale banner, no next-island unlock | PASS | generic onKilled sets Heart_kraken; maelstrom not in order → no unlock; `extra.finale` banner |
| The fight itself (pacing, exposure window length, tentacle reach, arena readability) | STUDIO | the headline playtest |

## FAIL bucket

**None found at 4793d70.** Every phase bullet is structurally satisfied or
deferred to Studio. Caveats that are *not* failures but worth knowing:
- The solid ocean slab is still walkable everywhere by design; containment
  only polices locked-island footprints. Walking 3000 studs is legal (slow).
- Rim-wall machinery (and therefore harbor notches) is dormant until an
  island declares a `rim` block again.
- The adversarial review fleet (round 2) may surface *behavioral* bugs beyond
  static reach; its confirmed findings route through the fix crew as before.

## STUDIO bucket — the morning playtest script

**Imports first** (everything else is untestable until these land —
follow `docs/import-checklist.md`):
1. Import the 6-island pack (or per-island .glb), FishPack (34), CreaturePack
   (69), RodPack (36), WeaponPack (35), BoatPack (6 + shelf) — set
   PreciseConvexDecomposition on island base parts, delete superseded models,
   re-export `assets/Assets.rbxm`, restart `rojo serve`.
2. BoatPack bow check: summon a boat; if the bow points backwards, tell the
   art session — one axis flip + regen is prepared.

**Fresh-profile end-to-end** (the plan's final verification):
1. New profile: spawn Starter Cove, fish, craft, level to 7. Ambient mobs
   wander the beach; hold for one raid (45s warning → 3 waves → payout).
2. Leviathan's Call → Brinejaw → banner + heart + **Cove Skiff granted** (R
   summons it at the shore). Check the Trophy Hall (H) and the shelf on deck.
3. Sail (don't teleport) to Blackmire Fen: bob/steer feel, hull DoT if you
   stray, dock approach. Fish Swamp_Water, try bow → crossbow → flintlock,
   fight the gulls (dive telegraph → grounded punish), let a skythief steal a
   catch and chase it. Old Gnashroot at 14.
4. Ironbog Hull → Frostmaw Reach: ice-hole fishing, blizzard (fog + flyer
   sky), long rifle zoom + revolver. Rimefang at 21.
5. Icebreaker Prow → Ashfall Caldera: eruption window (rings → bombs),
   Cinderlock full-auto feel + rate limit, Basalt Scattergun up close.
   Pyrelisk at 28.
6. Ashguard Plating → Gloomtrench: the dark + lantern rods (Lanternline
   doubles vision), Riptide SMG / DMR. Noctyss at 35.
7. Abyssal Lanterns → Wreckwater: boarding raid waves, blunderbuss.
   Admiral Wrack at 42.
8. Stormbreaker Keel → level 48 → craft Kraken's Call (verify it refuses
   before all six hearts) → the Maelstrom is visible/enterable only now →
   cast into the whirlpool → **the Kraken**: tentacles melee-able, head
   immune until the ring is down, guns during exposure windows, brood
   flyers, wreckage-storm P3 → Heart_kraken + finale banner.
9. Rejoin: everything persists (level, gear, bait, materials, hearts,
   BoatTier, cleared islands).

**Feel/tuning list** (expect refinement prompts): boat accel/turn/bob;
raid wave sizes + rewards; eruption bomb density; blizzard fog depth; flyer
dive speed; ranged recoil/zoom/tracers; boss HP/attack numbers island by
island; all new island looks (shorelines, docks, water surfaces, prop
density); every "unreviewed" row in context.md's status table.
