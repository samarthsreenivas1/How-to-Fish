# Volcano content spec — creatures, fish, materials

Handoff doc, not user-facing. Author: roblox-game-2b (2026-08-23), on user
direction to spec the volcano roster and split the build between 2b and 2f.

The user approved an **original** volcano roster (not reskins of the ocean
hostiles). This spec turns that into concrete rows. Everything here is designed
to be **testable the moment the data lands** — the fish are floppers, and the
hostiles ship on existing archetypes so they fight immediately, with the
signature "new mechanic" layered on afterward by 2f. Meshes are a later pass
(reuse recolored existing shapes for now).

## The split

| Half | Owner | Files | Status |
|------|-------|-------|--------|
| **Data** | **2b** | `Materials.luau` (volcano mats), `Creatures.luau` (fish + hostile rows) | shipping with this doc |
| **Behaviour** | **2f** | `CreatureService.luau` (new archetype updaters), `FishingService.luau` (island/water roll filter) | handed off |
| Meshes (later) | 83 | `creatures_gen.py` / `fish_gen.py` volcano species | follow-up, not blocking |
| Bait using volcano mats (later) | 2f | `Bait.luau` | follow-up |

The two halves are independent: 2b's rows fight correctly on their fallback
archetypes with no 2f work, and 2f's filter + new archetypes deepen them
without touching 2b's rows.

## Critical dependency — the roll is not island-scoped (2f)

`FishingService.rollCreature` pulls from `Creatures.byRarity` **globally** —
there is no water/island filter today. Without one, volcano creatures roll on
the ocean island and ocean fish roll in the lava. **2f must add the filter.**

Design:
- 2b tags every volcano row with **`waters = "volcano"`** (a new optional field
  on the creature row; missing = ocean, so no existing row changes).
- `rollCreature` (and `allowedRows`) filter the pool to rows whose `waters`
  matches the **water the cast landed in**: lava (`Volcano_Lava`) → only
  `waters == "volcano"` rows; ocean (`Ocean`) → only rows with no `waters` (or
  `waters == "ocean"`).
- The landed cast already knows its surface — `CastAim.FISHABLE_NAMES`
  distinguishes `Ocean` from `Volcano_Lava`. Thread the claimed surface part's
  name into `rollCreature` so it can filter. (The claim carries the surface Y
  today; it needs to also carry the name, or the water kind derived from it.)
- Keep the graceful fallbacks intact: if a water's filtered pool is empty for a
  tier, that tier simply doesn't roll there (same as the perk-floor fallback).

## Archetypes — fallback now, signature later (2f)

`CreatureService` degrades an **unknown archetype to the passive flopper**
branch (verified: `ARCHETYPE_UPDATERS[...]` nil → default flop). So new
archetype names never crash — they just stand still until implemented. To avoid
inert "hostiles," 2b ships each hostile on the **closest existing archetype**
(so it fights now) and names the intended new mechanic in a row comment. 2f
either adds a genuinely new archetype (and flips the row's `archetype`) or
enhances the existing one.

New mechanics 2f should build (most-wanted first):
- **crust** (Slagheart Golem) — armoured: takes heavily reduced damage until its
  glowing core is exposed (e.g. after N hits / a heavy hit cracks the crust,
  then a vulnerable window). Ships as `shambler`.
- **splitter** (Magma Ooze) — on death (or on taking a big hit) divides into two
  smaller, weaker oozes; the smalls don't split again. Ships as `rusher`.
- **reborn** (Ashfeather Phoenix) — on death, revives **once** at ~40% HP after a
  short down-time, then must be killed again. Ships as `charger`.
- **thornback** (Obsidian Shardback) — reflects a fraction of melee damage back
  at the puncher when hit from the front; vulnerable from behind. Ships as
  `rusher`.
- **gascloud** (Cinder Djinn) — trails a lingering burning smoke volume that
  damages the player over time (a moving hazard, not a projectile). Ships as
  `shambler`.
- **magnetize** (Lodestone Eel) — periodically pulls the player toward it
  (drag/impulse), making spacing hard. Ships as `charger`.

Fumarole (`spitter`) and Ember Swarm (`drifter`) fit existing archetypes as-is
— no new archetype needed, just volcano flavour.

## Materials (2b — `Materials.luau`)

All `tier = "rare"` (dropped on kill, not pulled up on a plain cast), volcano
palette. Icons empty until art.

| id | name | rarity | source |
|----|------|--------|--------|
| `ember` | Ember | Uncommon | common volcano fish + Ember Swarm |
| `sulfur` | Sulfur | Uncommon | Fumarole, Cinder Djinn, some fish |
| `obsidian_shard` | Obsidian Shard | Rare | obsidian fish, Shardback |
| `magma_core` | Magma Core | Epic | high-tier fish, golem, ooze |
| `lodestone` | Lodestone | Epic | Lodestone Eel |
| `phoenix_ash` | Phoenix Ash | Legendary | Ashfeather Phoenix (endgame gear) |

## Volcano fish (2b — all `flopper`, `waters="volcano"`)

Reuse existing FishPack species shapes recolored to a lava palette until
dedicated meshes exist.

| id | name | rarity | health | reuse species | drops |
|----|------|--------|--------|---------------|-------|
| `emberfin_perch` | Emberfin Perch | Common | 70 | Perch | ember {1,2} |
| `ashgill_minnow` | Ashgill Minnow | Common | 65 | Mackerel | ember {1,1}, sulfur {1,1} |
| `magma_guppy` | Magma Guppy | Common | 80 | Trout | ember {1,2} |
| `obsidian_bass` | Obsidian Bass | Uncommon | 210 | Bass | obsidian_shard {1,2} |
| `basalt_cod` | Basalt Cod | Uncommon | 250 | Cod | obsidian_shard {1,2}, sulfur {1,1} |
| `pyre_salmon` | Pyre Salmon | Rare | 360 | Salmon | magma_core {1,1}, obsidian_shard {1,2} |
| `magmafin_tuna` | Magmafin Tuna | Epic | 660 | Tuna | magma_core {1,2}, obsidian_shard {2,3} |

## Volcano hostiles (2b — `waters="volcano"`)

`archetype` = the shipping (fallback) archetype; the intended signature mechanic
is in the → note (2f).

| id | name | rarity | health | archetype (ships) | → intended | reuse shape | drops |
|----|------|--------|--------|-------------------|-----------|-------------|-------|
| `fumarole` | Fumarole | Uncommon | 190 | spitter | — (fits) | gulletcod | sulfur {1,2}, ember {1,2} |
| `ember_swarm` | Ember Swarm | Uncommon | 150 | drifter | — (fits) | jelly | ember {2,3} |
| `magma_ooze` | Magma Ooze | Rare | 240 | rusher | splitter | urchin | magma_core {1,1}, sulfur {1,2} |
| `obsidian_shardback` | Obsidian Shardback | Rare | 320 | rusher | thornback | crab | obsidian_shard {2,3} |
| `cinder_djinn` | Cinder Djinn | Rare | 260 | shambler | gascloud | zombie (upright) | sulfur {1,2}, ember {2,3} |
| `lodestone_eel` | Lodestone Eel | Epic | 480 | charger | magnetize | skipper | lodestone {1,2}, magma_core {1,1} |
| `slagheart_golem` | Slagheart Golem | Epic | 460 | shambler | crust | zombie (upright) | magma_core {1,2}, obsidian_shard {2,3} |
| `ashfeather_phoenix` | Ashfeather Phoenix | Epic | 500 | charger | reborn | ray | phoenix_ash {1,1}, magma_core {1,1} |

## 2f's half — DONE (2026-08-23)

Both pieces landed; stylua / selene 0/0/0, rojo clean. All six rows flipped to
their real archetypes, so nothing is running on a fallback any more.

**Water filter.** `World.WATERS_BY_PART` maps a fishable part name to its pool;
`CastAim.isWater` returns that as a third value; `validateLanding` passes it on
(from the server's own probe, never the claim); `allowedRows` filters on it. A
row without `waters` is an ocean row, so no existing row changed. **The shoal
and chain baits filter too** — chumming the lava brings up lava fish, and a
Bloodbait chain started in the crater stays volcano (`chainWaters` rides the
`extra` bag).

**Archetypes.** Each delegates movement to the ocean archetype it shipped on
and adds only the new behaviour, so none reimplements pathing or contact damage:

- `crust` / `reborn` live in the **damage path**, not an updater — armour has to
  apply to poison and explosions too, not just punches, and the phoenix's first
  death must be intercepted before `kill()` so no listener (loot, the chain, a
  boss participant list) ever sees it.
- `splitter` spawns its halves inside `kill()`, before the model goes, while
  `pos` is still meaningful. Halves carry `noSplit`, so a fight is bounded at
  three bodies. They pay coins/XP at `bounty = SPLIT_BOUNTY` but **no materials
  at all** (`suppressDrops`): an ooze is one loot unit and the parent drops the
  row's mats once. A bounty cannot express that — MaterialService floors every
  roll at `math.max(1, ...)`, so even 0.4 still pays a whole Magma Core per
  half, tripling a premium Epic material off one Rare kill (caught by 2b).
  `spawn` gained `extra.scale` / `extra.healthMult` for them (scale applied
  BEFORE the orientation measure, or `halfThickness` describes the wrong body).
- `thornback` is entirely in `hitModifiers`, which gained an optional `from`.
  Note: cleave splash and poison go through `damage()` directly and so bypass
  its plating — deliberate, but worth knowing.
- `gascloud` puffs are ticked in the **update walk**, not the updater, so they
  keep burning while the djinn is juggled, stunned or already dead.
- `magnetize` reuses the boss lure's **client-side `pull` event** rather than
  setting velocity on the server. A player's character is owned by their own
  client, so a server-side shove is unreliable; the existing event applies a
  ramped VectorForce on the owner and is already tested.

Untested in play — all of it needs a Studio pass, especially the numbers.

## Deferred (not in this split)

- **Volcano boss** — the user wants it *last*, and it needs the ranged weapons
  first (the multi-phase emerge-from-lava setpiece). Not specced here.
- **Volcano rods / weapons / bait** — the volcano materials above are the inputs
  for these; recipes come later.
- **Dedicated volcano meshes** — 83's `*_gen.py` pass; the rows above render on
  recolored existing shapes until then.
