--!nonstrict
-- Bait.luau
-- Craftable, consumable bait, as rows - the same id-keyed shape as Materials /
-- Rods / Weapons. A bait is a stackable count the player owns (BaitService,
-- mirroring MaterialService), crafted from materials (CraftingService), selected
-- like a rod, and spent one-per-cast to change what that cast pulls up and what
-- it's worth (FishingService).
--
-- THINNED 2026-08-25 (docs/revamp-plan.md): every island carries exactly three
-- baits - two utility, one legendary boss-summon. Nine baits were cut; every
-- one of their effect fields survives on a keeper here or returns on a later
-- island's bait, so no effect code is orphaned.
--
-- A BAIT'S EFFECT MUST BE SOMETHING YOU WATCH HAPPEN (user, 2026-08-22, and
-- again 2026-08-23). This file used to be full of hidden multipliers - "your
-- loot odds are 1.35x" - and the verdict was that crafting bait felt pointless,
-- because you use one, catch a fish, and cannot tell it did anything. The test
-- a new effect has to pass is "what will the player SEE that is different?",
-- not "what number moved?". Do not reintroduce a field here before the code
-- that reads it exists.
--
-- The `effect` block, every field of which is live:
--   luck           - multiplies the rod's luck in the rarity roll (>1 = rarer).
--   rewardMult     - multiplies the coins / XP / cast materials the catch pays.
--   stun           - seconds the catch lands dazed for, unable to act.
--   hostileOnly    - never lands a passive fish; the catch always fights back.
--   guaranteedDrop - the kill gives the TOP of every material range, not a roll.
--   summonsBoss    - the cast summons this boss instead of rolling a catch.
--   shoal          - this many extra fish surface alongside the catch.
--   chain          - killing the catch calls another hostile, this many times.
--   salvage        - no fish at all: the cast drags up materials and coins.
--   enrage         - the catch arrives at the Enraged grade (tougher, faster,
--                    hits harder) and pays about double.
--   hatchling      - seconds a friendly companion fights alongside you.
--
-- IMPORTANT (no catch-22): a bait must NOT cost a material that only drops from
-- something you need that bait to reach. Bait is crafted from what fishing
-- itself gives (driftwood / kelp / fish scale / pearl) plus mats from creatures
-- reachable without it.
--
-- Recipes reuse the Rods/Weapons recipe shape plus a `yield`: bait is made in
-- batches, so one craft grants `yield` of it.

local Bait = {}

export type Effect = {
	luck: number?,
	rewardMult: number?,
	-- Effects you can SEE, rather than another hidden multiplier:
	stun: number?, -- the catch lands dazed for this many seconds and can't act
	hostileOnly: boolean?, -- never lands a passive fish; always something that fights
	guaranteedDrop: boolean?, -- the kill is certain to give up its rare material
	shoal: number?, -- this many extra fish surface alongside the catch
	chain: number?, -- killing the catch calls another hostile, this many times
	salvage: boolean?, -- no fish: the cast drags up a haul of materials + coins
	enrage: boolean?, -- the catch arrives Enraged - tougher, faster, pays more
	hatchling: number?, -- seconds a friendly companion fights alongside you
	-- Not a fishing modifier at all: the cast summons this boss id instead of
	-- rolling a catch. FishingService checks the gate BEFORE spending the bait,
	-- so a rejected summon costs nothing.
	summonsBoss: string?,
}

-- Like Rods.Recipe / Weapons.Recipe, plus `yield` (how many bait one craft
-- makes). Declared here rather than imported, matching the other content files.
-- `requiresHearts` (Bosses ids, checked against the Heart_<bossId> attributes,
-- never spent) is here for the final summon bait to come (Kraken's Call).
export type Recipe = {
	requiresLevel: number,
	coins: number,
	materials: { [string]: number }, -- keyed by Materials id
	yield: number,
	requiresHearts: { string }?,
}

export type Bait = {
	id: string,
	name: string,
	description: string,
	rarity: string, -- Common | Uncommon | Rare | Epic | Legendary - how it's shown
	icon: string, -- inventory image asset id ("rbxassetid://..."); "" = blank placeholder
	color: Color3, -- reward-pop text + recipe-row dot colour
	effect: Effect,
	recipe: Recipe,
}

Bait.items = {} :: { [string]: Bait }

-- ============================================================ Starter Cove

Bait.items.chum = {
	id = "chum",
	name = "Chum",
	description = "A slick of mashed bait spread wide on the water. It doesn't draw one fish - it draws the whole shoal.",
	rarity = "Common",
	icon = "",
	color = Color3.fromRGB(176, 138, 104),
	-- Deliberately the plainest effect in the file: it's a 15-coin Common. One
	-- extra fish comes up with the catch, and you can see it lying there.
	effect = { shoal = 1, rewardMult = 1.2 },
	recipe = {
		requiresLevel = 2,
		coins = 15,
		materials = { kelp_fiber = 2, driftwood = 3 },
		yield = 5,
	},
}

Bait.items.bloodbait = {
	id = "bloodbait",
	name = "Bloodbait",
	description = "Ground gore and fish oil. It doesn't call a fish - it calls the things with claws, and they keep coming while the water stays red.",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(196, 92, 72),
	-- Blood in the water: each kill draws the next one to the same spot, and
	-- each link is rolled luckier than the last, so the fight escalates as long
	-- as you keep winning it.
	effect = { chain = 3, hostileOnly = true, luck = 1.2 },
	recipe = {
		requiresLevel = 4,
		coins = 150,
		materials = { fish_scale = 6, kelp_fiber = 6 },
		yield = 3,
	},
}

-- The capstone. Not a fishing modifier at all: casting with this SUMMONS the
-- island boss instead of rolling a catch (FishingService reads `summonsBoss`,
-- checks the boss gate, consumes the bait, and calls BossService.summonFor).
-- Its recipe is a trophy of the island's bestiary - a signature drop off the
-- things you had to hunt to get here. Single-use.
Bait.items.leviathans_call = {
	id = "leviathans_call",
	name = "Leviathan's Call",
	description = "A grim lure knotted from trophies of the cove's deep-dwellers. Cast it, and Brinejaw answers. One use.",
	rarity = "Legendary",
	icon = "",
	color = Color3.fromRGB(120, 255, 214), -- the boss's lure-glow teal
	effect = { summonsBoss = "brinejaw" },
	recipe = {
		requiresLevel = 7,
		coins = 600,
		materials = {
			fish_scale = 12,
			pearl = 4,
			barnacle_chitin = 5,
			cursed_bone = 5,
			nacre = 4,
			volt_gland = 3,
		},
		yield = 1,
	},
}

-- ============================================================ Blackmire Fen
-- The swamp's three (revamp Session 2): two utility, one boss-summon, gated
-- up the fen's L8-14 band.

Bait.items.glowgrub = {
	id = "glowgrub",
	name = "Glowgrub",
	description = "A fat grub that swallowed a mote of wisp light. What takes it comes up blinded and reeling.",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(150, 235, 200),
	-- The stun bait's fen successor: six seconds of free hits, and the light
	-- draws slightly stranger things up.
	effect = { stun = 6, luck = 1.15 },
	recipe = {
		requiresLevel = 9,
		coins = 200,
		materials = { bog_iron = 4, kelp_fiber = 4 },
		yield = 4,
	},
}

Bait.items.dredge_lure = {
	id = "dredge_lure",
	name = "Dredge Lure",
	description = "A weighted rake-lure that combs the fen floor. It brings up no fish at all - just everything the bog has swallowed.",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(164, 98, 62),
	-- Gravelure's fen successor: the no-fish cast, paid in materials and
	-- coins straight out of the murk, scaled by the minigame grade.
	effect = { salvage = true, rewardMult = 1.3 },
	recipe = {
		requiresLevel = 11,
		coins = 400,
		materials = { bog_iron = 6, gator_scute = 4 },
		yield = 3,
	},
}

Bait.items.tyrants_call = {
	id = "tyrants_call",
	name = "Tyrant's Call",
	description = "A snarl of root, scute and cold flame that smells like a challenge. Cast it, and Old Gnashroot answers. One use.",
	rarity = "Legendary",
	icon = "",
	color = Color3.fromRGB(150, 235, 200), -- the Tyrant's wisp-lit glare
	effect = { summonsBoss = "old_gnashroot" },
	recipe = {
		requiresLevel = 14,
		coins = 1200,
		materials = {
			fish_scale = 12,
			bog_iron = 8,
			gator_scute = 8,
			wisp_light = 5,
			fen_venom = 4,
			pearl = 3,
		},
		yield = 1,
	},
}

-- ============================================================ Ashfall Caldera
-- The volcano's three (it had zero bait before the thinning pass). INTERIM
-- GATES: L8-14 while the volcano is still island 2 (docs/revamp-plan.md);
-- they re-gate to L22-28 when it slides to slot 4.

Bait.items.ember_roe = {
	id = "ember_roe",
	name = "Ember Roe",
	description = "Roe cured in cinders until it smoulders. What takes it comes up burning mad - a far harder fight, and a far richer one.",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(240, 132, 52),
	-- Forces the Enraged grade: +25% health, +40% damage, +35% speed and 1.5x
	-- rewards, on top of which `rewardMult` takes the payout to about double.
	-- The one bait that makes the fight itself harder.
	effect = { enrage = true, rewardMult = 1.35 },
	recipe = {
		requiresLevel = 9,
		coins = 260,
		materials = { ember = 8, sulfur = 6 },
		yield = 3,
	},
}

Bait.items.magma_chum = {
	id = "magma_chum",
	name = "Magma Chum",
	description = "Chum bound around a sliver of magma core. Whatever it draws up is carrying its best - and gives all of it up when it dies.",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(244, 96, 40),
	-- Kills the "I rolled badly on the drop" feeling: the catch is guaranteed
	-- to give up the top of every material range, so this is how you farm one.
	effect = { guaranteedDrop = true, rewardMult = 1.3 },
	recipe = {
		requiresLevel = 11,
		coins = 450,
		materials = { magma_core = 3, obsidian_shard = 6 },
		yield = 2,
	},
}

Bait.items.calderas_call = {
	id = "calderas_call",
	name = "Caldera's Call",
	description = "A lure of obsidian and living embers, hot enough to wake the mountain's own heart. Cast it, and Pyrelisk answers. One use.",
	rarity = "Legendary",
	icon = "",
	color = Color3.fromRGB(255, 96, 16), -- the wyrm's molten glow
	effect = { summonsBoss = "pyrelisk" },
	recipe = {
		requiresLevel = 14,
		coins = 1200,
		materials = {
			ember = 15,
			sulfur = 12,
			obsidian_shard = 10,
			magma_core = 6,
		},
		yield = 1,
	},
}

-- Stable display order for the crafting / inventory bait tabs (table iteration
-- order isn't guaranteed). By island, then by tier.
Bait.order = {
	"chum",
	"bloodbait",
	"leviathans_call",
	"glowgrub",
	"dredge_lure",
	"tyrants_call",
	"ember_roe",
	"magma_chum",
	"calderas_call",
}

return Bait
