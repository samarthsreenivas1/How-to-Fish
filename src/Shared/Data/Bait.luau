--!nonstrict
-- Bait.luau
-- Craftable, consumable bait, as rows - the same id-keyed shape as Materials /
-- Rods / Weapons. A bait is a stackable count the player owns (BaitService,
-- mirroring MaterialService), crafted from materials (CraftingService), selected
-- like a rod, and spent one-per-cast to change what that cast pulls up and what
-- it's worth (FishingService).
--
-- A BAIT'S EFFECT MUST BE SOMETHING YOU WATCH HAPPEN (user, 2026-08-22, and
-- again 2026-08-23). This file used to be full of hidden multipliers - "your
-- loot odds are 1.35x" - and the verdict was that crafting bait felt pointless,
-- because you use one, catch a fish, and cannot tell it did anything. The test
-- a new effect has to pass is "what will the player SEE that is different?",
-- not "what number moved?".
--
-- Worse, four of those multipliers (`lootLuck` / `calls` / `hard` / `double`,
-- plus a `baitTag` gate described here as if it existed) were declared and read
-- by NOTHING in src - five baits advertised effects that did not run. They were
-- deleted on 2026-08-23 and those baits given real mechanics instead. Do not
-- reintroduce a field here before the code that reads it exists.
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
export type Recipe = {
	requiresLevel: number,
	coins: number,
	materials: { [string]: number }, -- keyed by Materials id
	yield: number,
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

-- ============================================================ Common

Bait.items.worm = {
	id = "worm",
	name = "Grub Worm",
	description = "A fat grub on the hook. Fish can't help themselves - a little luckier line.",
	rarity = "Common",
	icon = "",
	color = Color3.fromRGB(150, 116, 92),
	effect = { luck = 1.2 },
	recipe = {
		requiresLevel = 1,
		coins = 10,
		materials = { kelp_fiber = 3 },
		yield = 5,
	},
}

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

-- ============================================================ Uncommon

Bait.items.shiny_minnow = {
	id = "shiny_minnow",
	name = "Shiny Minnow",
	description = "A flashing baitfish that pulls the rarer things up out of the deep.",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(168, 198, 220),
	effect = { luck = 1.4 },
	recipe = {
		requiresLevel = 4,
		coins = 60,
		materials = { fish_scale = 4, kelp_fiber = 4 },
		yield = 4,
	},
}

Bait.items.fortune_fly = {
	id = "fortune_fly",
	name = "Fortune Fly",
	description = "A gilded lure. What takes it is worth a good deal more in coin and experience.",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(240, 202, 96),
	effect = { rewardMult = 1.5 },
	recipe = {
		requiresLevel = 5,
		coins = 90,
		materials = { fish_scale = 3, driftwood = 5, pearl = 1 },
		yield = 4,
	},
}

-- ============================================================ Rare
-- Where bait stops being a modifier on a normal cast and changes what the cast
-- IS: a fight that keeps coming, or no fight at all.

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
		requiresLevel = 7,
		coins = 150,
		materials = { fish_scale = 6, kelp_fiber = 6 },
		yield = 3,
	},
}

Bait.items.gravelure = {
	id = "gravelure",
	name = "Gravelure",
	description = "A weighted lure that drags the bottom instead of the shallows. Nothing bites it - but it comes up loaded with what the drowned left behind.",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(120, 200, 150),
	-- The only cast in the game with no fight at all: it pays materials and
	-- coins straight out of the water. The bait you use when you want to craft,
	-- not brawl - every other bait is about the catch.
	effect = { salvage = true, rewardMult = 1.3 },
	recipe = {
		requiresLevel = 8,
		coins = 200,
		materials = { fish_scale = 8, pearl = 1 },
		yield = 3,
	},
}

-- ============================================================ Epic

Bait.items.frenzy_bait = {
	id = "frenzy_bait",
	name = "Frenzy Bait",
	description = "Bait that whips the catch into a thrashing fury. The fight is far harder - and pays far more.",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(228, 84, 64),
	-- Forces the Enraged grade: +25% health, +40% damage, +35% speed and 1.5x
	-- rewards, on top of which `rewardMult` takes the payout to about double.
	-- The one bait that makes the fight itself harder.
	effect = { enrage = true, rewardMult = 1.35, luck = 1.4 },
	recipe = {
		requiresLevel = 10,
		coins = 260,
		materials = { fish_scale = 6, pearl = 2 },
		yield = 3,
	},
}

Bait.items.split_roe = {
	id = "split_roe",
	name = "Split Roe",
	description = "Blessed spawn, and one of them hatches on the way up. The little thing that comes out fights on your side until it tires.",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(236, 226, 168),
	-- The only bait that gives you an ALLY: a friendly hatchling that hunts
	-- hostiles alongside you, then leaves. Nothing else in the game fights for
	-- the player, which is the whole reason it's worth an Epic craft.
	effect = { hatchling = 60, luck = 1.3 },
	recipe = {
		requiresLevel = 12,
		coins = 400,
		materials = { pearl = 3, fish_scale = 10 },
		yield = 2,
	},
}

-- ============================================================ New creature mats
-- Made from what the later hostiles drop. Their effects are deliberately
-- things you SEE happen (a dazed catch, a fight you asked for, a guaranteed
-- drop) rather than another invisible luck multiplier - that was the whole
-- reason bait felt pointless to craft (user, 2026-08-22).

Bait.items.glowchum = {
	id = "glowchum",
	name = "Glowchum",
	description = "Moonbell jelly mashed into chum. Whatever takes it comes up dazed by the light - and can't fight back until it comes round.",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(150, 226, 236),
	-- The catch lands stunned: its behaviour is suspended for this long, so
	-- even a hostile just flops there and takes free hits.
	effect = { stun = 6, luck = 1.15 },
	recipe = {
		requiresLevel = 6,
		coins = 120,
		materials = { moonjelly = 4, kelp_fiber = 6 },
		yield = 4,
	},
}

Bait.items.venom_roe = {
	id = "venom_roe",
	name = "Venom Roe",
	description = "Roe cured in a Gullet Cod's gland. No ordinary fish will touch it - only things that bite back, and they carry the good materials.",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(160, 214, 120),
	-- The danger bait: never lands a passive fish, always something hostile.
	-- Worth it because only hostiles drop the advanced crafting mats.
	effect = { hostileOnly = true, rewardMult = 1.25 },
	recipe = {
		requiresLevel = 11,
		coins = 300,
		materials = { brine_gland = 5, fish_scale = 8 },
		yield = 3,
	},
}

Bait.items.gilded_chum = {
	id = "gilded_chum",
	name = "Gilded Chum",
	description = "Ground hermit shell, still crusted with coin. Whatever it draws up is carrying something - and gives it up when it dies.",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(255, 206, 110),
	-- Kills the "I rolled badly on the drop" feeling: the catch is guaranteed
	-- to give up its rare material, so this is how you farm a specific one.
	effect = { guaranteedDrop = true, rewardMult = 1.3 },
	recipe = {
		requiresLevel = 14,
		coins = 480,
		materials = { gild_shell = 6, pearl = 2, skitterfin = 4 },
		yield = 2,
	},
}

-- ============================================================ Boss summon
-- The capstone. Not a fishing modifier at all: casting with this SUMMONS the
-- island boss instead of rolling a catch (FishingService reads `summonsBoss`,
-- checks the boss gate, consumes the bait, and calls BossService.summonFor).
-- Its recipe is a trophy of the whole bestiary - the signature rare drop off
-- every creature (minus the boss's own Brineheart, to avoid a catch-22) - so
-- you can only call Brinejaw once you've hunted everything. Level-15 gated by
-- the recipe; single-use.
Bait.items.leviathans_call = {
	id = "leviathans_call",
	name = "Leviathan's Call",
	description = "A grim lure knotted from a trophy of every deep-dweller you've bested. Cast it, and Brinejaw answers. One use.",
	rarity = "Legendary",
	icon = "",
	color = Color3.fromRGB(120, 255, 214), -- the boss's lure-glow teal
	effect = { summonsBoss = "brinejaw" },
	recipe = {
		requiresLevel = 15,
		coins = 2000,
		materials = {
			fish_scale = 15,
			pearl = 5,
			barnacle_chitin = 4,
			cursed_bone = 4,
			skitterfin = 3,
			brine_gland = 3,
			gild_shell = 3,
			moonjelly = 3,
			tidebomb_spine = 3,
			lurker_hide = 3,
			nacre = 3,
			volt_gland = 2,
		},
		yield = 1,
	},
}

-- Stable display order for the crafting / inventory bait tabs (table iteration
-- order isn't guaranteed). Cheapest first, then by tier.
Bait.order = {
	"worm",
	"chum",
	"shiny_minnow",
	"glowchum",
	"fortune_fly",
	"bloodbait",
	"gravelure",
	"frenzy_bait",
	"venom_roe",
	"split_roe",
	"gilded_chum",
	"leviathans_call",
}

return Bait
