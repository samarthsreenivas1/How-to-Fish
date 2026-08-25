# Progression Revamp: The 7-Island Saga — Master Design

This is the master design for the full progression revamp, executed across 4 Claude sessions
(prompts at the bottom). Written 2026-08-25. If a session changes a decision here, update this
file in the same commit.

## Rollout status (overnight run, 2026-08-25 — maintained by the coordinating session)

Five sessions executed this plan in parallel lanes on one shared checkout:
S2 src = f4 · S3 src = 5a · S4 src (all) = b8 · weapon/boat/creature art = 16 ·
islands + coordination = 81. Decisions taken along the way (all recommended-path):
**interim volcano re-gate skipped** — every island ships straight at its FINAL
band/position from the table below; the sparse L15–21 window existed only while
Frostmaw was being written the same night.

- [x] S1 — persistence (DataService) + thinning + Pyrelisk + hearts framework (f293308)
- [x] Baseline commit of prior volcano-session WIP (11a650b)
- [x] Art: six ranged weapon meshes in WeaponPack (8253923)
- [x] Art: Swamp / Frostmaw / Gloomtrench / Wreckwater island meshes + 6-island pack (8a15622)
- [x] S2 shapes milestone: ranged remotes/type/Tuning + flyer & skythief archetypes (d855af6)
- [ ] S2 full: shot pipeline, controllers, swamp data, volcano final slot + guns — f4
- [ ] S3 boat: BoatService/Controller, tiers, mayEnter + containment sweep — 5a
- [ ] S3 raids: SpawnerService, RaidService, Hazards, eruption, WeatherController — 5a (after S2)
- [ ] S4a: Frostmaw/Gloomtrench/Wreckwater data + volcano final re-gate + blizzard — b8
- [ ] S4b: Maelstrom site, Kraken, TrophyController, trophy shelf — b8 (after S3)
- [ ] Art: BoatPack, boss/flyer creature meshes, fish species — 16
- [ ] Final integration review + verification sweep — 81
- [ ] **Manual (user, in Studio): imports per docs/import-checklist.md**

## Context

The game before this revamp: two islands with bloated, uneven content — 22 rods (14 on the
volcano alone), 22 melee weapons, 12 baits, 21 materials, level gates crammed into L1–26 and
nothing beyond. Most items were stat-shuffles; the volcano had no boss so the chain dead-ended;
the bait ladder stopped at L15; coins had no sink besides crafting; nothing persisted.

The revamp restructures the game into a 7-island saga. Each island carries a thin, meaningful
loadout — **5 rods, 5 weapons, 3 baits, ~4 signature materials** — keeps high creature variety,
ends in a summoned boss whose **heart is kept as a trophy** (never spent on crafting), and
introduces one signature mechanic that becomes the norm on later islands. After the first boss
the player earns a **drivable boat**; boat upgrades (coins + materials) gate each crossing.
Collecting all six hearts lets the player craft **Kraken's Call** and summon the final boss at
The Maelstrom.

## Decisions locked in (user-approved 2026-08-24)

1. **Ranged weapons are IN**, overturning the previously binding "no guns or ranged weapons,
   ever" decision in context.md and the Weapons.luau header. Flavor arc: **fantasy early,
   modern late** — swamp: bow/crossbow/flintlock; ice: long rifle (sniper) + revolver; volcano
   (slot 4) onward: real modern firearms (full-auto). Both docs must record the overturn when
   ranged lands (Session 2).
2. **Ashfall Caldera moves to slot 4** — all existing volcano art, creatures, and materials are
   reused as the mid-game lava island. New swamp and ice islands become slots 2 and 3.
3. **Drivable boat** — a real vehicle crossing the shared ocean plane, with upgrade tiers as the
   coin sink and a boss-heart trophy shelf on deck.

## Island order

1. **Starter Cove** (tropical, exists) — fundamentals; boss: Brinejaw (exists). Reward: the boat.
2. **Blackmire Fen** (swamp, new) — introduces ranged tier 1 (bow/crossbow/flintlock), flying mobs, murky water.
3. **Frostmaw Reach** (ice, new) — introduces precision ranged (long rifle/revolver), ice-hole fishing, blizzards, first island raid.
4. **Ashfall Caldera** (existing volcano, relocated) — introduces full-auto firearms, eruption raids.
5. **Gloomtrench** (new) — perpetual dark, lantern/light management mechanic.
6. **Wreckwater** (new) — ghost-ship graveyard, boarding raids.
7. **The Maelstrom** (finale site, not a normal island) — Kraken summoned via Kraken's Call (requires all 6 hearts).

## Key codebase facts the plan builds on

- Recipes are inlined per item row; `CraftingService.luau` is item-agnostic — content thinning is pure data-file work.
- Boss engine is fully data-driven (`Bosses.luau` + `archetype = "boss"` creature row + `Islands.items[x].boss`); summon-by-bait (`effect.summonsBoss`) already works via `FishingService`.
- Enemy-side projectile machinery (server `throwGlob`/spit tables + client pooled glob rendering + `CastAim` ray validation) is the reusable basis for player ranged weapons. Melee's `RequestAttack` carries no arguments.
- No ambient spawner existed before Session 3 (all spawns were fishing-driven) — required for raids.
- One shared ocean plane, islands 3000 studs apart — boats are physically viable. Boat must key off `World.WATER_Y`, not the tide-animated visual plane.
- Persistence (DataService) lands in Session 1 and is the prerequisite for the heart-collection meta.
- New island meshes require Blender/python-gen art + a **manual Studio import** into `assets/Assets.rbxm` — per-island bottleneck; batch imports, keep procedural fallbacks so code never blocks on art.

---

## Content design

### Core content rules (apply everywhere)

- **Per-island kit:** exactly 5 craftable rods, 5 craftable weapons, 3 baits (2 utility + 1 legendary boss-summon), 4 signature materials, 1 boss + heart, 1 Legendary chase fish. Starters (`twig_rod`, `fists`) sit outside the count. Universal materials everywhere: `driftwood`, `kelp_fiber` (basic), `fish_scale`, `pearl` (rare).
- **Rarity ladder** (islands 2–7): item slots U / R / R / E / **L**; materials U / U / R / E. Island 1 keeps its C–L tutorial spread.
- **Hearts:** implemented as replicated **`Heart_<bossId>` Player attributes** set in `BossService.onKilled` (the `Cleared_` pattern — free replication, persists as one small dict, drives trophy UI + boat shelf + Kraken gate), *not* material rows. Recipes gain an optional **`requiresHearts: {string}`** field checked against the attributes so the crafting card renders "Requires: Mireheart ✓". Each island's Legendary rod + weapon require that island's heart; **Kraken's Call requires owning all 6 hearts — hearts are never spent**. `brineheart` and `phoenix_ash` leave the material economy.
- **Legendary tier armed:** `Tuning.Rarity.WEIGHTS.Legendary = 0.4`; every island gets one Legendary chase fish (big rewards, drops the island's Epic mat ×2–3).
- **Ranged data shape** (one optional block on the existing Weapon row; `nil` = pure melee):
  ```luau
  ranged: {
      projectileSpeed: number, range: number,
      fireMode: "single" | "scoped" | "auto",
      magazine: number, reloadTime: number,
      spread: number?, pellets: number?,  -- shotguns
      arc: boolean?,                       -- bows: ballistic draw + landing re-check
      zoomFov: number?,                    -- scoped
  }
  ```
  Balance rule: ranged sustained DPS ~10–20% under same-tier melee (safety premium), burst above it.
- **`waters` keys** per island (existing FishingService filter): island 1 = nil, then `"swamp"`, `"ice"`, `"volcano"` (exists), `"gloom"`, `"wreck"`, `"maelstrom"`.
- **Per-island payouts:** explicit `rewards` blocks on new rows at island multipliers **×1 / 2 / 3.5 / 6 / 10 / 16 / 25** (coins + XP) vs the `Tuning.Rewards.BY_RARITY` island-1 baseline.

### Level bands & world layout

Keep `XP_BASE 60 / XP_EXPONENT 1.35 / MAX_LEVEL 50`. Islands in a line, 3000 studs apart (ocean auto-sizes via `oceanSpan()`). Travel to island N+1 = unlockLevel AND `Cleared_` island N AND boat tier N (boat gate from Session 3).

| # | Island | id | Band | unlock | Boss bait | worldPosition |
|---|---|---|---|---|---|---|
| 1 | Starter Cove | `tropical` | L1–7 | 0 | L7 | (0,0,0) |
| 2 | Blackmire Fen | `swamp` | L8–14 | 8 | L14 | (3000,0,0) |
| 3 | Frostmaw Reach | `ice` | L15–21 | 15 | L21 | (6000,0,0) |
| 4 | Ashfall Caldera | `volcano` | L22–28 | 22 | L28 | (9000,0,0) — final; interim slots during rollout |
| 5 | Gloomtrench | `gloom` | L29–35 | 29 | L35 | (12000,0,0) |
| 6 | Wreckwater | `wreck` | L36–42 | 36 | L42 | (15000,0,0) |
| 7 | The Maelstrom | `maelstrom` | L43–50 | 43 | L48 | (18000,0,0), `site = true`, out of `Islands.order` |

Within a band, gates: U at A, R at A+1, R at A+3, E at A+4/5, Legendary at band end (heart-gated).

**Rollout interim states** (keep the game playable after every session):
- After S1: tropical (final, L1–7) → volcano at slot 2, unlock 8, interim gates L8–14, rewards ×2.
- After S2: tropical → swamp (final, slot 2) → volcano at slot 3, (6000,0,0), unlock 15, gates L15–21, rewards ×3.5, guns added.
- After S4: full final table above.

### Boat tiers (`Shared/Data/Boats.luau`, crafted via CraftingService — Session 3)

| Tier | Name | Cost | Unlocks crossing to |
|---|---|---|---|
| 1 | Cove Skiff | **free — granted on Brinejaw kill** | Blackmire Fen |
| 2 | Ironbog Hull | 1,500c + bog_iron 20 + gator_scute 10 | Frostmaw Reach |
| 3 | Icebreaker Prow | 4,000c + glacier_shard 20 + everice 8 | Ashfall Caldera |
| 4 | Ashguard Plating | 9,000c + obsidian_shard 25 + magma_core 6 | Gloomtrench |
| 5 | Abyssal Lanterns | 18,000c + lantern_gland 15 + abyss_ichor 6 | Wreckwater |
| 6 | Stormbreaker Keel | 35,000c + spectral_sailcloth 15 + wraith_essence 8 | The Maelstrom |

### Island 1 — Starter Cove (reuse pass, L1–7)

- **Materials (4 sig):** keep `barnacle_chitin`, `nacre`, `cursed_bone`, `volt_gland`. **Cut:** skitterfin, brine_gland, gild_shell, moonjelly, tidebomb_spine, lurker_hide — creature drops remap to surviving mats (skipper/gullet_cod→fish_scale, hermit→pearl, moonbell→kelp_fiber+pearl, urchin/sand_lurker→barnacle_chitin).
- **Rods keep 5:** bamboo (U,L2) · anglers (U,L3) · reefmaw (R,L4) · bonecaster (E,L5, keeps shambler lock) · brineheart_rod (L,L7 — **requiresHearts brinejaw**; volt_gland 6 + cursed_bone 8 + nacre 5, 1,500c). Cut: abyssal, voltline.
- **Weapons keep 5:** driftwood_club (C,L2) · scale_blade (U,L3) · shellcrusher (R,L4) · drowncleaver (E,L5) · heartrender (L,L7 — **requiresHearts brinejaw**; cursed_bone 12 + volt_gland 6 + nacre 4, 1,200c). Cut: tidebomb_maul, voltfang.
- **Baits keep 3:** chum (C,L2) · bloodbait (R,L4) · leviathans_call (L,L7, 600c, recipe simplified to surviving mats). Cut 9: worm, shiny_minnow, fortune_fly, glowchum, gravelure, frenzy_bait, venom_roe, split_roe, gilded_chum (every effect field survives in later-island successors — no effect code orphaned).
- **Creatures:** keep all 20 ocean rows (drop remap above); brinejaw gate 15→**7**. Add **Sunking Coelacanth** (Legendary flopper, 900 HP, drops volt_gland 2–3 + pearl 2–3).

### Island 2 — Blackmire Fen (swamp, L8–14) — introduces ranged, flyers, murky water

- **Materials:** `bog_iron` (U), `gator_scute` (U), `wisp_light` (R), `fen_venom` (E). Heart: `mireheart`.
- **Creatures (13 + boss):** Peat Darter / Mudwhisker Catfish / Bog Bream (C floppers) · Rustgill Gar (U flopper) · **Bog Gull (U flyer, dive-bomber)** · Croakjaw Toad (U spitter) · Mire Leech (U rusher) · Snagtooth Gator (R charger) · **Will-o-Wisp (R flyer)** · **Dread Dragonfly (R flyer)** · Sunken Trapper (R mimic) · Fen Serpent (E spitter) · Peat Revenant (E shambler) · **The Golden Gar (L flopper)**.
- **Rods:** Reedlash (U, freeMisses 1, L8) · Gatorback (R, noShrink, L9) · Wisplight (R, streakLuck .12/.6, L11) · Fenpiercer (E, minRarity U + castRange 1.5, L12) · **Mireheart Rod** (L, 2.00/1.45/1.40, minRarity R + castRange 1.6 + freeMisses 2, L14, requiresHearts).
- **Weapons (2 melee / 3 ranged):** Bogwood Bow (ranged U, 28–40, cd .9, arc, mag 1, ~76 dps, L8) · Rustfang Machete (melee R, poison, L9) · Gatorjaw Crossbow (ranged R, 90–120, cd 1.3, mag 1, no perk, L11) · Mire Flintlock (ranged E, 110–150, cd 1.8, mag 1, execute, L12) · **Fenreaver** (melee L, ~171 dps, lifesteal, L14, requiresHearts).
- **Baits:** Glowgrub (U, stun 6 + luck 1.15, L9) · Dredge Lure (R, salvage + rewardMult 1.3, L11) · **Tyrant's Call** (L, summons `old_gnashroot`, L14, 1,200c).
- **Boss — Old Gnashroot, the Fen Tyrant** (moss-backed snapping turtle-gator, ~16,000 HP): P1 snap/tail/slam → P2 (0.65) dive into the peat murk + brood (toads, gulls) + pull → P3 (0.3) volley + spines. Heart `mireheart`.

### Island 3 — Frostmaw Reach (ice, L15–21) — introduces precision ranged, ice-holes, blizzards, first raid

- **Materials:** `glacier_shard` (U), `rime_pelt` (U), `everice` (R), `aurora_essence` (E). Heart: `frostheart`.
- **Creatures (13 + boss):** Icemelt Smelt / Frostfin Char / Snowdrift Sculpin (C floppers) · Rime Herring (U flopper) · Frostbite Pup (U rusher) · **Hailfin Skua (U flyer)** · Iceshard Crab (U rusher) · Glacial Lurker (R burrower, under the ice sheet) · Frozen Mariner (R shambler) · Aurora Jelly (R drifter) · Icevein Pike (E charger) · Blizzard Wraith (E gascloud) · **Aurorafin Marlin (L flopper)**.
- **Rods:** Auger (U, freeMisses 2, L15) · Rimebound (R, noShrink, L16) · Silverscale (R, streakLuck .14/.7, L18) · Aurora (E, minRarity R, L19) · **Frostheart Rod** (L, 2.10/1.50/1.45, minRarity R + noShrink + castRange 1.5, L21, requiresHearts).
- **Weapons (3 melee / 2 ranged):** Icepick Hatchet (melee U, frenzy, L15) · Frostbore Long Rifle (ranged R scoped, 160–210, cd 2.6, mag 1, execute, L16) · Glacier Maul (melee R, uproot, L18) · Frostbite Revolver (ranged E, 38–52, cd .45, mag 6, reload 1.8, poison, L19) · **Rimefang Lance** (melee L, ~204 dps, execute, L21, requiresHearts).
- **Baits:** Frostgrub (U, stun 8, L16) · Gilded Herring (R, rewardMult 1.6, L18) · **Glacier's Call** (L, summons `rimefang`, L21, 2,500c).
- **Boss — Rimefang, the Glacier Serpent** (~26,000 HP): P1 snap/tail/volley (ice shards) → P2 (0.65) dive (tunnels UNDER the ice, bursts up — ice-holes turned against you) + brood → P3 (0.3) slam (shatters the shelf) + spines (icicle rain in a scripted blizzard whiteout). Heart `frostheart`.

### Island 4 — Ashfall Caldera (volcano reuse pass, L22–28) — introduces full-auto, eruption raids

- **Materials keep 4:** `ember`, `sulfur`, `obsidian_shard`, `magma_core`. Cut: `lodestone` (eel drops remap), `phoenix_ash` (phoenix drops magma_core; rod keeps the name as flavor). Heart: **`cinderheart`**.
- **Creatures:** keep all 15 volcano rows (health ×~2.2, rewards ×6 final); **promote Ashfeather Phoenix to Legendary** (chase fish).
- **Rods keep 5, re-gate/re-cost:** cinderline (U,L22) · obsidian (R,L23) · cinderglass (R,L25) · magma_core (E,L26) · **phoenix_ash_rod** (L,L28, stats buffed to 2.20/1.60/1.45, requiresHearts pyrelisk). Cut 9: fumarole, ashcane, pumice, basalt, sootline, lodestone, emberforge, lodefire, vent_warden.
- **Weapons keep 2 melee + add 3 guns (S2):** **Cinderlock Carbine** (ranged U, first full-auto: 15–21, cd .13, mag 24, ~110 dps, L22) · Obsidian Piercer (melee R, buffed, execute, L23) · **Basalt Scattergun** (ranged R, 6 pellets, mag 2, close-range burst, L25) · Magma Gauntlets (melee E, buffed, frenzy, L26) · **Vulkan Repeater** (ranged L, auto, mag 40, ~200 dps, poison "Incendiary Rounds", L28, requiresHearts pyrelisk). Cut 12: ember_cudgel, cinderclub, sulfur_knuckles, pumice_fists, cinderlash, ridgeback_pike, slagfist_gauntlet, cinder_spear, lodestone_maul, riftcleaver, sootveil_blade, slagheart_warhammer.
- **Baits (all new — volcano had zero):** Ember Roe (R, enrage + rewardMult 1.35, L23) · Magma Chum (E, guaranteedDrop + rewardMult 1.3, L25) · **Caldera's Call** (L, summons `pyrelisk`, L28, 5,000c).
- **Boss — Pyrelisk, the Caldera Wyrm** (magma serpent in the lava ponds, ~40,000 HP final): P1 snap/volley/slam → P2 (0.6) dive (swims the lava channels) + brood (**magma oozes — splitters, the adds multiply**) + pull → P3 (0.3) spines (summit-eruption ember rain) + tail. Heart `cinderheart` → `Heart_pyrelisk`.

### Island 5 — Gloomtrench (abyss, L29–35) — introduces light/lantern management

- **Materials:** `gloom_scale` (U), `trench_chitin` (U), `lantern_gland` (R), `abyss_ichor` (E). Heart: `gloomheart`.
- **Creatures (12 + boss):** Pale Dace / Blindcave Sardine / Sootgill Hagfish (C floppers) · Gulper Eel (U spitter) · Flashbulb Squid (U drifter, blinding pop) · Trench Skitterer (U charger) · Lanternjaw Angler (R mimic — a hanging light that snaps) · Vampire Squid (R thief) · Pressure Crab (R thornback) · Void Ray (E pulser) · Silt Stalker (E burrower) · **Ghostlight Oarfish (L flopper)**.
- **Rods:** Lanternline (U, freeMisses 2, L29) · Trenchglass (R, minRarity U + castRange 1.5, L30) · Inkveil (R, streakLuck .16/.8, L32) · Voidline (E, minRarity R + noShrink, L33) · **Gloomheart Rod** (L, 2.35/1.60/1.50, minRarity E + castRange 1.8, L35, requiresHearts).
- **Weapons (2 melee / 3 ranged):** Trenchspike (melee U, L29) · Abyssal Harpooner (ranged R, 140–190, mag 1, L30) · Riptide SMG (ranged R, auto, mag 30, ~160 dps, L32) · Voidglass Saber (melee E, lifesteal, L33) · **Gloomcaller DMR** (ranged L scoped, 180–240, cd .8, mag 8, execute "Lights Out", L35, requiresHearts).
- **Baits:** Lanternbait (R, luck 1.8, L30) · Duskbrood Roe (E, hatchling 90 + luck 1.3, L32) · **Trench Mother's Call** (L, summons `noctyss`, L35, 10,000c).
- **Boss — Noctyss, the Trench Mother** (abyssal angler-queen; her lure is the only light in the arena, ~60,000 HP): P1 pull (the lure flares, dragging you toward the maw) / snap / volley (ink) → P2 (0.6) dive + brood → P3 (0.3) spines + slam; enrage douses her lure between attacks. Heart `gloomheart`.

### Island 6 — Wreckwater (ghost-fleet graveyard, L36–42) — introduces boarding raids

- **Materials:** `ghost_plank` (U), `tarnished_doubloon` (U), `spectral_sailcloth` (R), `wraith_essence` (E). Heart: `wraithheart`.
- **Creatures (13 + boss):** Wreck Herring / Rustscale Snapper / Barnacle Blenny (C floppers) · Ghost Carp (U flopper) · **Rigging Wraith (U flyer)** · Cannonball Crab (U rusher) · Drowned Boatswain (R shambler) · Phantom Moray (R charger) · Cursed Chest (R mimic) · Plunder Sprite (R thief) · Ghostfire Jelly (E gascloud) · Wailing Gunner (E spitter, spectral grapeshot) · **Spectral Sailfish (L flopper)**.
- **Rods:** Ghostplank (U, freeMisses 2, L36) · Riggingline (R, noShrink + freeMisses 1, L37) · Doubloon (R, streakLuck .18/.9, L39) · Sailcloth (E, minRarity R + castRange 1.7, L40) · **Wraithheart Rod** (L, 2.50/1.65/1.55, minRarity E + noShrink + castRange 1.8, L42, requiresHearts).
- **Weapons (3 melee / 2 ranged):** Boarding Axe (melee U, cleave, L36) · Grave Blunderbuss (ranged R, 8 pellets, close-range ~226 dps, L37) · Phantom Repeater (ranged R, auto, mag 32, ~240 dps, L39) · Cutlass of the Fleet (melee E, frenzy, L40) · **Admiral's Saber** (melee L, ~360 dps, execute "Strike the Colors", L42, requiresHearts).
- **Baits:** Corpse Chum (R, hostileOnly + chain 2, L37) · Plunder Lure (E, salvage + rewardMult 1.6, L39) · **Admiral's Summons** (L, summons `admiral_wrack`, L42, 20,000c).
- **Boss — Admiral Wrack, the Fleet-Eater** (drowned admiral fused into his flagship's bow, ~85,000 HP): P1 volley (cannon broadside) / snap (anchor bite) / tail (boom sweep) → P2 (0.6) brood (**a boarding party — the raid mechanic inverted**) + pull (grappling chains) → P3 (0.3) spines (grapeshot rain) + dive (the wreck surfaces under you). Heart `wraithheart`.

### Island 7 — The Maelstrom (finale, L43–50) — everything combined

- **Materials:** `storm_glass` (U), `riptide_scale` (U), `thunder_pearl` (R), `maelstrom_core` (E). Heart: **`krakenheart`** (pure trophy).
- **Creatures (13 + boss):** Squall Sprat / Rainfin Mackerel / Foamchaser Mullet (C floppers) · **Stormpetrel + Galestreak Flyingfish (U flyers)** · Riptide Barracuda (U charger) · Cyclone Ray (R pulser) · Whirlpool Horror (R burrower) · Tempest Revenant (R shambler) · Thunderlance Marlin (E charger) · Stormcaller Djinn (E gascloud) · Kraken Spawn (E splitter) · **The Stormking Tuna (L flopper)**.
- **Rods:** Squallcaster (U, L43) · Riptide (R, minRarity R + castRange 1.6, L44) · Thunderhead (R, streakLuck .20/1.0, L46) · Eyewall (E, minRarity R + noShrink, L47) · **Krakenheart Rod** (L, **2.70/1.80/1.70 — best in game**, minRarity E + castRange 2.2 + noShrink, L50, requiresHearts kraken).
- **Weapons (2 melee / 3 ranged):** Galecleaver (melee U, L43) · Cyclone Assault Rifle (ranged R, auto, mag 30, ~320 dps, L44) · Thunderhead Hand Cannon (ranged R, 210–280, mag 5, L46) · Stormlance (melee E, poison "Static Charge", L47) · **Krakenfang** (melee L, ~545 dps endgame blade, lifesteal "Devour the Storm", L50, requiresHearts kraken).
- **Baits:** Stormbait (E, shoal 3 + enrage, L44) · Deepcall Roe (E, guaranteedDrop + luck 1.5, L46) · **Kraken's Call** (L, summons `kraken`, L48, 50,000c — **gate: level 48 AND own all six hearts, checked not spent**).
- **Final boss — The Kraken, Maw of the Maelstrom** (~130,000 HP; tentacles melee-targetable, `rangedOnly` head, flyer brood — see Systems §5): every prior boss's signature returns — P1 snap/tail/slam/volley → P2 (0.65) pull (Noctyss) + dive (Rimefang) + brood of splitters (Pyrelisk) → P3 (0.4) all eight attacks, spines = thrown-wreckage storm (Wrack). Drops `krakenheart` + finale banner.

### Economy coherence

Coin income per Uncommon kill by island: ~16 / 32 / 56 / 96 / 160 / 256 / 400. Craft bands: I1 15–1,500c → I7 10,000–55,000c; every tier ≈ 20–50 on-island kills (constant effort, rising numbers). Boss baits ≈ half the island's Legendary craft; boss payouts refund the bait ×2–3; boat tiers are the big between-island sink.

### Migration summary (file diff shape)

- **Rods.luau** — keep 11 (starter + 5 I1 + 5 I4, two with recipe rework to `requiresHearts`), cut 11, add 25. `Recipe` type += `requiresHearts: {string}?`. Rebuild `Rods.order`; `LOCKED_ARCHETYPES` unchanged.
- **Weapons.luau** — keep 8 (fists + I1 five + obsidian_piercer + magma_gauntlets, buffed), cut 14, add 28. `Weapon` type += `ranged` block. Header's "never a ranged row" struck (S2).
- **Bait.luau** — keep 3 (chum, bloodbait, leviathans_call reworked), cut 9, add 18 → 21 total.
- **Materials.luau** — keep 12 (hearts become attributes, brineheart removed as material), cut 8, add 20 signature (4 × 5 new islands) → ~32 total.
- **Creatures.luau** — keep all 37 (drop remaps; volcano rebalance; phoenix → Legendary), add ~66 new rows (6 Legendary chase + ~60 island rows) + 6 boss rows; new `flyer` archetype on ~8 rows; `waters` keys.
- **Bosses.luau** — brinejaw gate 15→7; add 6 entries (old_gnashroot, rimefang, pyrelisk, noctyss, admiral_wrack, kraken — kraken with `parts`/`rangedOnly`/`vulnerableWhen`/`gate.hearts`).
- **Islands.luau** — 7 entries per the band table; volcano moves; each gets `boss`, `waters`, `ambient`/`raid` blocks.
- **Tuning.luau** — `Rarity.WEIGHTS.Legendary = 0.4`, new `Tuning.Ranged`, `Tuning.Raid`, `Tuning.Boat` sections.
- **context.md** — strike "No guns or ranged weapons, ever" (user approval 2026-08-24, applied in S2); update Slice 9 / in-memory headers when persistence lands (S1).

## Systems engineering

### 1. Ranged weapons — server-authoritative hitscan with cosmetic flight

**Approach:** client proposes a camera ray (the `CastAim` trust model); server re-validates origin (within `Tuning.Ranged.ORIGIN_SLACK` ~6 studs of the character), raycasts immediately against `{Workspace.Creatures, Workspace.World}` (so terrain blocks shots), resolves the creature via `CreatureService.findByPart`, and applies damage after a flight delay (`distance / projectileSpeed`) using the same "queue with a landAt clock" shape as `creature.globs`. Clients draw pooled tracers (fork of the `launchGlob` pool in `CreatureEventController`, direction reversed). For `arc = true` weapons (bows), at `landAt` re-test a small sphere (~3 studs) at the predicted impact against live creatures so a dodged arrow misses; guns apply the fire-time hit verbatim.

**Ammo model:** no crafted ammo (bait already owns the crafted-consumable niche); magazines are free but `reloadTime` is server-enforced. Server tracks `shotsInMag` per player.

**Rate limiting (full-auto exploit resistance):** per-player token bucket — `bucket = min(cap=2, bucket + (now-last)/cooldown)`, 1 token per shot, plus the magazine gate. A spamming client lands exactly `1/cooldown` shots/s.

**Flow:** new remotes in `src/Shared/Net/Remotes.luau` — `RequestShoot` (client→server: `rayOrigin, look`; melee's argument-less `RequestAttack` stays untouched) and `ShotFired` (server→all, for tracers). New shared `src/Shared/Modules/ShotAim.luau` (CastAim's sibling) validates both sides. `CombatService` owns a Heartbeat shot queue; landed shots reuse `Remotes.CreatureHit` so all existing impact feedback fires for free.

**Perk mapping:** poison / execute / lifesteal / frenzy work for ranged (extract `frenzyMultiplier` so both paths share the chain table); **cleave and uproot are melee-only**; ranged rows use knockback 0–4 and never `launch`.

**Client:** new `RangedController.luau` (fire loop, scoped FOV zoom, mag/reload UI) + `RangedFxController.luau` (tracer pool, muzzle flash); aim/recoil clips in `WeaponViewmodelController`; new procedural `shape`s ("bow", "gun") in `WeaponModel.luau` as pre-mesh fallbacks; new `Tuning.Ranged` section.

### 2. Flying mobs — `flyer` archetype (extends the drifter hover proof)

`ARCHETYPE_UPDATERS.flyer` mode machine: `circle` (orbit nearest player at ~16 studs up) → `windup` (hover tell + telegraph ring) → `dive` (straight line to the player's position *at dive start* — the dodge window, same rule as spitter landings) → `grounded` (1.2–2s recovery on the deck, **melee-hittable — the deliberate counterplay**) → climb. Hover height rides `creature.flyHeight` fed into `poseCFrame`'s hop term while `pos` stays ground-clamped, so bounds/knockback/LINGER all work untouched. `KNOCKBACK_MULT_BY_ARCHETYPE.flyer = 0.15`, launch 0.

**Skythief** (aerial thief variant): swoops a resting passive fish, carries it (pivots the carried anchored model under itself, keeps its `lastFoughtAt` fresh), flies out to sea; kill it to drop the cargo, or lose both. The thief's steal/flee loop with a creature as loot.

### 3. Drivable boat — VehicleSeat + constraints, client-owned while driven

Boat = server-built Model (procedural hull/deck/mast via a `BoatModel` builder in the `WeaponModel` style — no Studio import needed; mesh pack later): unanchored PrimaryPart hull, `VehicleSeat`, `LinearVelocity` + `AlignOrientation`. While driven: `hull:SetNetworkOwner(driver)`; the driver's `BoatController` holds `hull.Position.Y = World.WATER_Y + draft + bob(t)` — **keyed to the `World.WATER_Y` constant, never the tide-animated visual plane**. Custom collision group vs the solid ocean slab. Parked = re-anchored, server-owned. Spawn/recall via a menu tile/keybind (`RequestBoat`) to the nearest shoreline point; one boat per player.

**World integration (`WorldService.luau`):** notch the rim walls at dock mouths; factor the teleport gate checks into `WorldService.mayEnter(player, islandId)` and add a **containment sweep** to the existing 0.5s player loop — a player inside a locked island's radius gets teleported back (closes the walk-on-the-solid-ocean exploit; sailing and teleporting become one rule).

**Upgrade tiers:** `Shared/Data/Boats.luau` — `{tier, name, speed, hullHealth, seaworthiness, recipe}`, crafted through the existing item-agnostic `CraftingService`. **Seaworthiness gates crossings:** beyond that many studs from any unlocked island the hull takes escalating DoT and sinks (the under-map recovery net rescues dumped players).

**Teleport menu stays** as fast travel to unlocked islands; the boat is the scenic layer + raid/ocean platform + trophy shelf (deck mounts rendered from `Heart_<bossId>` attributes).

### 4. Ambient spawner, raids, island events

- **`SpawnerService` (new)** — first non-fishing spawns. Per-island `Islands.items[id].ambient = {rows, maxAlive, interval, ring}`; 2s tick spawns resting creatures 60–100 studs from players (no throw target). LINGER is the free cleanup. Global cap ~40 structs. Factor a shared `Islands.islandAt(position)` helper.
- **`RaidService` (new)** — per-island state machine `idle → announced (60s) → wave k of N → cleared|failed`, config in `Islands.items[id].raid`. Spawns with `{raid = true, noLinger = true}` — first-class `creature.noLinger` flag in the despawn check; Kraken tentacles reuse it. Participation credit unions `Killed.participants` per raid kill; payout on clear via the `BossService.onKilled` shape. Raid mobs carry reduced bounty / suppressed drops so raids don't out-earn fishing. New `RaidState` remote + `RaidHudController` (fork of `BossHudController`), filtered to the local player's island.
- **Events** — blizzard (ice): server window + `WorldEvent` remote; client `WeatherController` fogs locally; spawner biases flyers ×3. Eruption (volcano): server lava bombs on the `throwGlob` clock, telegraph ring → 1.2s → splash. **Refactor:** extract `damagePlayersInRadius`/`fireEvent` from CreatureService into server module `Hazards.luau` shared by CreatureService/RaidService/events.

### 5. Boss hearts + Kraken finale

- **Hearts = replicated Player attributes `Heart_<bossId>`** (the `Cleared_` pattern), set in `BossService.onKilled`, not spendable materials — read by the trophy UI (`TrophyController.luau`), the boat shelf, and the Kraken gate.
- **The Maelstrom = terminal site, not an island:** `Islands.items.maelstrom` with `site = true`, far worldPosition, **no mesh — WorldService builds it procedurally** (rock ring + whirlpool VFX + fightable rock platforms inside tentacle reach). Kept **out of `Islands.order`** so the linear `Cleared_` chain and `onKilled`'s next-island lookup are untouched. Hidden from travel until hearts complete; `BossService.qualifies` gains `gate.hearts = true` (owning all 6 — never spent).
- **Kraken composition:** tentacles = ordinary creature rows (`archetype = "tentacle"`, planted AoE attackers, `noLinger` + suppressed drops), spawned by a `parts` field on the Bosses entry. Head = the boss creature with `row.rangedOnly = true` (melee target-pick skips it) and `vulnerableWhen = "partsDown"` (untargetable while tentacles live → exposure window → `regrow`). Flyer adds via the existing `brood` attack. Head's `Killed` → `Heart_kraken` + finale banner; no next island. Boss HUD stays head-only.

### 6. Persistence — hand-rolled `DataService`, first in boot ORDER

Not ProfileService (the codebase is deliberately framework-free): ~200 lines around `UpdateAsync` with session locking (`{lockId, lockedAt}`; live foreign lock <90s → retry ×3 → kick with a friendly message; never silently play unlocked except Studio-without-API, loudly warned). Autosave 60s staggered + PlayerRemoving + `BindToClose`.

```luau
export type Profile = {
    version: number,  -- for v = data.version+1, CURRENT do MIGRATIONS[v](data) end
    coins: number, xp: number, level: number,
    items: {string}, equippedRod: string?, equippedWeapon: string?,
    bait: {[string]: number}, materials: {[string]: number},
    cleared: {[string]: boolean},  -- → Cleared_* attributes on load
    hearts: {[string]: boolean},   -- → Heart_* attributes
    boatTier: number,
}
```
Integration: each owning service (ProgressionService, InventoryService, MaterialService, BaitService, BossService/attrs, BoatService) gains `load(player, slice)` / `serialize(player)` registered with `DataService.register`; load overwrites the existing PlayerAdded defaults and re-pushes the existing update remotes. Not saved: selected bait, live casts/creatures.

## Implementation phases

**[IMPORT]** = manual Studio `.glb` → `assets/Assets.rbxm` step (human-in-Studio; batch several per session).

| Phase | Contents | Size | Depends on |
|---|---|---|---|
| **P0 Persistence** | DataService + load/serialize on the 4 state services + cleared/hearts fields | M | — |
| **P0.5 Content thinning** | Cut islands 1 & 4 to 5/5/3, materials trim, re-gate, Pyrelisk (data-only), hearts framework | M | — |
| **P1 Ranged core** | Shot pipeline + controllers + Tuning.Ranged + doc-decision strike | L | P0 |
| **P2 Flyers** | flyer + skythief archetypes, rows, telegraph FX | M | P1 |
| **P3 Swamp ships** | mesh [IMPORT], Islands entry, roster, boss, ranged recipes | M | P1, P2 |
| **P4 Spawner → Raids → Events** | SpawnerService, Hazards, RaidService + HUD, blizzard/eruption, noLinger | L | P2 |
| **P5 Boat** | BoatService/Controller, tiers, harbor notches, mayEnter sweep, trophy shelf | L | P0 |
| **P6 Islands 3–5** | per island: mesh [IMPORT] + data + rosters + event hooks | M each | P3, P4 |
| **P7 Hearts + Finale** | TrophyController, boat shelf, Maelstrom site, Kraken | L | P1, P5, P6 |

Critical path: P0 → P1 → P2 → P3 → P6 → P7; P4 and P5 run as parallel tracks.

## Session breakdown & prompts

- **S1:** P0 persistence + P0.5 thinning + Pyrelisk + hearts framework + this document.
- **S2 — Ranged & Flyers update:** P1 + P2 + P3; volcano shifts to interim slot 3 (L15–21, ×3.5) and gains its 3 guns.
- **S3 — World update:** P5 boat + P4 spawner/raids/eruption + Hazards extraction + containment sweep.
- **S4 — Saga update:** P6 Frostmaw Reach, Gloomtrench, Wreckwater; volcano to final slot 4 (L22–28, ×6); blizzard; P7 Maelstrom + Kraken + trophy UI.

### Session 2 prompt
> Read docs/revamp-plan.md — this is Session 2 of 4 of the progression revamp. Build: (1) The ranged weapon engine per the plan's Systems §1: RequestShoot/ShotFired remotes, ShotAim shared module (CastAim's sibling with ORIGIN_SLACK validation), a CombatService shot queue (hitscan at fire time, damage after distance/projectileSpeed, arc weapons re-check a ~3-stud sphere at landing), token-bucket rate limiting + magazine/reload server-side, perk mapping (poison/execute/lifesteal/frenzy work ranged; cleave/uproot stay melee-only), new RangedController + RangedFxController (fork the glob pool in CreatureEventController), viewmodel aim/recoil clips, procedural "bow"/"gun" shapes in WeaponModel, Tuning.Ranged. Strike the "no guns or ranged weapons, ever" decision in context.md and the Weapons.luau header — user overturned it 2026-08-24. (2) The flyer archetype + skythief per Systems §2 (circle/windup/dive/grounded machine extending the drifter hover; grounded recovery is the melee counterplay). (3) Ship Blackmire Fen as island slot 2 per the plan's Island 2 tables: write assets/island_swamp_gen.py in the style of the existing island gen scripts, Islands entry at (3000,0,0) unlock 8, the full 5/5/3 kit, 13 creatures + 1 Legendary chase, Old Gnashroot boss + mireheart, waters="swamp". Shift volcano to interim slot 3: position (6000,0,0), unlock 15, re-gate its content to L15–21, rewards ×3.5, and add its 3 guns (Cinderlock Carbine, Basalt Scattergun, Vulkan Repeater with requiresHearts pyrelisk). Remind me to import the swamp .glb in Studio — code must not block on it (missing mesh = island closed, which is the existing safe behavior). Verify with the plan's P1/P2 verification bullets plus a full fish→fight→craft regression on Starter Cove.

### Session 3 prompt
> Read docs/revamp-plan.md — this is Session 3 of 4 of the progression revamp. Build: (1) The drivable boat per Systems §3: BoatService + BoatController, procedural hull via a BoatModel builder (WeaponModel style — no Studio import needed), VehicleSeat + LinearVelocity/AlignOrientation, network ownership to the driver, Y locked to World.WATER_Y (NEVER the tide-animated visual plane), custom collision group vs the ocean slab, spawn/recall to the nearest shoreline, Boats.luau tiers crafted through the existing CraftingService (tier 1 free on Brinejaw kill; tier costs in the plan's boat table), seaworthiness DoT past each tier's range, harbor notches in the rim walls, and WorldService.mayEnter + the 0.5s containment sweep that bounces players out of locked islands (ship the sweep regardless — it also closes the walk-on-the-ocean hole). Keep the teleport menu as fast travel. Add the boat-tier requirement to island travel gates. (2) Ambient spawning + raids per Systems §4: SpawnerService (per-island ambient rosters, ring spawns near players, LINGER cleanup, global cap), the shared Islands.islandAt helper, Hazards.luau extraction of damagePlayersInRadius/fireEvent, RaidService wave state machine with noLinger creatures and participants-based payouts, RaidState remote + RaidHudController (fork BossHudController, filter to the local island), and the volcano eruption event (telegraphed lava bombs on the throwGlob clock). Wire ambient + raid rosters for tropical, swamp, and volcano. Blizzard waits for the ice island next session. Verify with the plan's P4/P5 verification bullets.

### Session 4 prompt
> Read docs/revamp-plan.md — this is Session 4 of 4 of the progression revamp. Build, in order: (1) Frostmaw Reach at slot 3 per the plan's Island 3 tables — gen script, (6000,0,0), unlock 15, L15–21, ice-hole fishing surface (waters="ice"), full kit incl. Frostbore Long Rifle + Frostbite Revolver, Rimefang boss + frostheart, blizzard event via WeatherController + flyer spawn bias, and its raid roster. (2) Slide volcano to final slot 4: (9000,0,0), unlock 22, re-gate content to L22–28, rewards ×6. (3) Gloomtrench at slot 5 and Wreckwater at slot 6 per their island tables (gen scripts, full kits, Noctyss + gloomheart, Admiral Wrack + wraithheart, boarding-raid roster). (4) The finale per Systems §5: Maelstrom as a procedurally-built site (site=true, out of Islands.order, hidden until all 6 Heart_* attributes), TrophyController + boat trophy shelf, Kraken's Call bait gated on owning all six hearts (checked, never spent), and the Kraken fight — tentacle archetype creatures (noLinger, suppressed drops), rangedOnly head with vulnerableWhen="partsDown" minion gating and regrow, flyer brood, Heart_kraken + finale banner with no next-island unlock. Batch all .glb Studio imports into one reminder list for me. Verify with the plan's P7 verification bullets plus the full end-to-end: fresh profile → all 7 islands → Kraken kill.
