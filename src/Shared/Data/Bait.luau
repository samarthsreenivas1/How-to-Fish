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
		requiresLevel = 23,
		coins = 1500,
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
		requiresLevel = 25,
		coins = 2800,
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
		requiresLevel = 28,
		coins = 5000,
		materials = {
			ember = 15,
			sulfur = 12,
			obsidian_shard = 10,
			magma_core = 6,
		},
		yield = 1,
	},
}

-- ============================================================ Frostmaw Reach

Bait.items.frostgrub = {
	id = "frostgrub",
	name = "Frostgrub",
	description = "A grub packed in rime. Whatever swallows it comes up numb to the bone - hardly able to fight at all, for a while.",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(190, 220, 240),
	-- The longest stun in the game so far: the ice does the fighting for you.
	effect = { stun = 8 },
	recipe = {
		requiresLevel = 16,
		coins = 350,
		materials = { rime_pelt = 4, kelp_fiber = 6 },
		yield = 4,
	},
}

Bait.items.gilded_herring = {
	id = "gilded_herring",
	name = "Gilded Herring",
	description = "A rime herring dipped in melted doubloon-gold. What takes it is carrying a rich man's share.",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(230, 190, 100),
	effect = { rewardMult = 1.6 },
	recipe = {
		requiresLevel = 18,
		coins = 800,
		materials = { glacier_shard = 6, fish_scale = 8, pearl = 1 },
		yield = 3,
	},
}

Bait.items.glaciers_call = {
	id = "glaciers_call",
	name = "Glacier's Call",
	description = "A lure of everice and aurora-light, cold enough to wake what sleeps under the sheet. Cast it, and Rimefang answers. One use.",
	rarity = "Legendary",
	icon = "",
	color = Color3.fromRGB(80, 220, 255), -- the serpent's ice-light
	effect = { summonsBoss = "rimefang" },
	recipe = {
		requiresLevel = 21,
		coins = 2500,
		materials = {
			glacier_shard = 12,
			rime_pelt = 10,
			everice = 8,
			aurora_essence = 4,
		},
		yield = 1,
	},
}

-- ============================================================ Gloomtrench

Bait.items.lanternbait = {
	id = "lanternbait",
	name = "Lanternbait",
	description = "A lantern gland, still warm, still lying. Down here light is the rarest thing there is - everything comes to see.",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(255, 226, 130),
	-- The biggest flat luck bonus in the game: the dark is starving for light.
	effect = { luck = 1.8 },
	recipe = {
		requiresLevel = 30,
		coins = 1800,
		materials = { lantern_gland = 2, gloom_scale = 8 },
		yield = 3,
	},
}

Bait.items.duskbrood_roe = {
	id = "duskbrood_roe",
	name = "Duskbrood Roe",
	description = "Roe of something that guards its young. One hatches on the hook and fights beside you, and its kin come looking.",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(170, 120, 255),
	-- A companion for a minute and a half, plus a luck kick - the trench's
	-- version of Split Roe, grown up.
	effect = { hatchling = 90, luck = 1.3 },
	recipe = {
		requiresLevel = 32,
		coins = 3200,
		materials = { abyss_ichor = 2, gloom_scale = 10, trench_chitin = 6 },
		yield = 2,
	},
}

Bait.items.trench_mothers_call = {
	id = "trench_mothers_call",
	name = "Trench Mother's Call",
	description = "A false lure built from her own stolen light. She does not forgive that. Cast it, and Noctyss rises. One use.",
	rarity = "Legendary",
	icon = "",
	color = Color3.fromRGB(255, 226, 130), -- her lure's warmth
	effect = { summonsBoss = "noctyss" },
	recipe = {
		requiresLevel = 35,
		coins = 10000,
		materials = {
			lantern_gland = 8,
			gloom_scale = 14,
			trench_chitin = 10,
			abyss_ichor = 5,
		},
		yield = 1,
	},
}

-- ============================================================ Wreckwater

Bait.items.corpse_chum = {
	id = "corpse_chum",
	name = "Corpse Chum",
	description = "Chum for a crueller sea. Only the fleet's dead answer it, and they answer in twos.",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(140, 160, 150),
	effect = { hostileOnly = true, chain = 2 },
	recipe = {
		requiresLevel = 37,
		coins = 3500,
		materials = { ghost_plank = 6, tarnished_doubloon = 6 },
		yield = 3,
	},
}

Bait.items.plunder_lure = {
	id = "plunder_lure",
	name = "Plunder Lure",
	description = "A doubloon on a hook, the oldest trick in any navy. Nothing bites - the line drags the seabed's plunder up instead.",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(230, 190, 100),
	-- The salvage cast: no fight at all, materials and coins straight out of
	-- the graveyard floor, scaled by the minigame grade.
	effect = { salvage = true, rewardMult = 1.6 },
	recipe = {
		requiresLevel = 39,
		coins = 6000,
		materials = { tarnished_doubloon = 8, spectral_sailcloth = 3 },
		yield = 2,
	},
}

Bait.items.admirals_summons = {
	id = "admirals_summons",
	name = "Admiral's Summons",
	description = "Written orders in the fleet's own cipher, weighted with doubloons: ALL HANDS. He comes to deliver the reprimand himself. One use.",
	rarity = "Legendary",
	icon = "",
	color = Color3.fromRGB(160, 255, 210), -- ghost-fire green
	effect = { summonsBoss = "admiral_wrack" },
	recipe = {
		requiresLevel = 42,
		coins = 20000,
		materials = {
			ghost_plank = 12,
			tarnished_doubloon = 16,
			spectral_sailcloth = 8,
			wraith_essence = 5,
		},
		yield = 1,
	},
}

-- ============================================================ Bait

Bait.items.stormbait = {
	id = "stormbait",
	name = "Stormbait",
	description = "Chum whipped through with storm-glass dust. The whole squall's worth of fish comes up with the catch, and none of it calm.",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(140, 190, 230),
	effect = { shoal = 3, enrage = true },
	recipe = {
		requiresLevel = 44,
		coins = 9000,
		materials = { storm_glass = 8, riptide_scale = 6 },
		yield = 3,
	},
}

Bait.items.deepcall_roe = {
	id = "deepcall_roe",
	name = "Deepcall Roe",
	description = "Roe from the storm's still centre. What answers it is carrying its very best, and gives up all of it.",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(90, 130, 255),
	effect = { guaranteedDrop = true, luck = 1.5 },
	recipe = {
		requiresLevel = 46,
		coins = 14000,
		materials = { maelstrom_core = 2, thunder_pearl = 4 },
		yield = 2,
	},
}

-- The saga's capstone. The recipe is gated on ALL SIX island hearts -
-- checked as Heart_* attributes, never spent - and BossService re-checks
-- the same gate at the summon.
Bait.items.krakens_call = {
	id = "krakens_call",
	name = "Kraken's Call",
	description = "Six hearts' worth of proof, knotted around a maelstrom core. Cast it into the storm, and the Maw itself answers. One use.",
	rarity = "Legendary",
	icon = "",
	color = Color3.fromRGB(150, 120, 255),
	effect = { summonsBoss = "kraken" },
	recipe = {
		requiresLevel = 48,
		coins = 50000,
		materials = {
			maelstrom_core = 6,
			thunder_pearl = 8,
			storm_glass = 10,
			riptide_scale = 10,
		},
		requiresHearts = { "brinejaw", "old_gnashroot", "rimefang", "pyrelisk", "noctyss", "admiral_wrack" },
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
	"frostgrub",
	"gilded_herring",
	"glaciers_call",
	"ember_roe",
	"magma_chum",
	"calderas_call",
	"lanternbait",
	"duskbrood_roe",
	"trench_mothers_call",
	"corpse_chum",
	"plunder_lure",
	"admirals_summons",
	"stormbait",
	"deepcall_roe",
	"krakens_call",
}

return Bait
