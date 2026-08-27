--!nonstrict
-- Rods.luau
-- Rod content, as rows rather than code. Every rod a player can hold -
-- starter gear, shop unlocks, crafted rods later - is one entry in
-- `Rods.items`, keyed by id. Adding a rod is a new entry here, never a new
-- code path.
--
-- THINNED 2026-08-25 (docs/revamp-plan.md): every island carries exactly five
-- craftable rods (U / R / R / E / Legendary), the starter apart, and each
-- island's Legendary is gated on that island's boss heart (recipe
-- `requiresHearts` - the Heart_<bossId> attribute BossService sets; owned,
-- never spent). Eleven stat-shuffle rods were cut; their perk effects all
-- survive on the keepers or on later islands' rods.
--
-- Stats stay to three, each centred on 1.0, so a rod's power is legible at a
-- glance and comparing two rods is just comparing three numbers:
--   luck    - multiplies the odds of a rare catch (the rarity roll, once the
--             reel minigame exists to feed it).
--   power   - multiplies cast distance and reel bar speed - a stronger rod
--             casts further and the marker sweeps faster (harder, but a
--             faster catch).
--   control - multiplies reel zone size - how forgiving the timing window
--             is. Higher control makes a good grade easier to land.

local Rods = {}

export type RodStats = {
	luck: number,
	power: number,
	control: number,
}

-- How the rod looks in the hand. `model` names a Model under
-- ReplicatedStorage/Assets - every rod is a variant in the shared "RodPack"
-- (imported once from assets/rod.glb - see assets/README.md). `variant` picks
-- which rod's parts to clone out of the pack (RodModel.assembleVariant).
-- `grip` is how far up the rod, in studs from the butt, the hand closes - it
-- must match GRIP_CENTER in the generator. `length` is butt-to-tip in studs -
-- must match ROD_LENGTH. RodViewmodelController uses grip and length together
-- to find the tip for the fishing line. `colors` recolours every part of the
-- rod - `twig` (shaft), `grip`, `trim` (guides / reel / bands / tip ring),
-- `line`, `bobberTop` / `bobberBottom` (the float above and below its
-- waterline); any key left out takes RodModel's default. `neon` lists the
-- generic part names (Rod_Trim, Rod_BobberTop...) that should glow.
export type RodModel = {
	model: string,
	variant: string,
	grip: number,
	length: number,
	colors: { [string]: Color3 },
	neon: { string }?,
}

-- Base layout for the reel minigame, before a cast's rod stats scale it.
-- FishingService multiplies barSpeed by the rod's `power` and both widths by
-- its `control` (see the stat comments above) to get the config a cast
-- actually plays with. One target per round - green surrounds red, sharing a
-- centre - so greenWidth must always stay wider than redWidth.
export type ReelConfig = {
	clicksRequired: number, -- rounds per cast
	barSpeed: number, -- marker sweeps the bar this many times per second
	redWidth: number, -- fraction of the bar's width, before the control multiplier
	greenWidth: number, -- must stay wider than redWidth; see ReelMath.buildZones
}

-- What it costs to craft this rod (CraftingService). A rod with no `recipe`
-- is not craftable - the starter, and any future shop-only rod. `materials`
-- is keyed by Materials id; `coins` is spent from ProgressionService;
-- `requiresLevel` gates it behind the player's level. `requiresHearts` lists
-- Bosses ids whose Heart_<bossId> attribute the player must carry (set by
-- BossService on the kill) - checked, never spent, so a heart-gated craft
-- stays craftable forever after the boss falls. Same shape describes weapon
-- and bait recipes - crafting is item-agnostic.
export type Recipe = {
	requiresLevel: number,
	coins: number,
	materials: { [string]: number },
	requiresHearts: { string }?,
}

-- A special fishing power-up, on the rarer rods only. `name`/`description` are
-- what the inventory and crafting cards show; the other fields are the actual
-- effect, each read by exactly one place:
--
--   minRarity      floors the catch roll - every tier below it is dropped
--                  (FishingService.rollCreature).
--   freeMisses     misses forgiven before the reel's zones start shrinking
--                  (Minigames.reel.shrinkFor).
--   noShrink       the reel's zones never shrink at all, however many you miss.
--   castRange      multiplier on how far this rod can cast (CastAim, both
--                  sides - the client gates its aim by it and the server
--                  validates against the same number).
--   callsArchetype unlocks a creature archetype that no other rod can hook
--                  (Rods.LOCKED_ARCHETYPES) and weights the roll toward it.
--   streakLuck     extra luck per consecutive completed cast, capped at
--                  streakMax; a cancelled cast resets the streak.
--
-- Optional: most rods have no perk.
export type Perk = {
	id: string,
	name: string,
	description: string,
	minRarity: string?,
	freeMisses: number?,
	noShrink: boolean?,
	castRange: number?,
	callsArchetype: string?,
	streakLuck: number?,
	streakMax: number?,
}

-- Creature archetypes that only a rod with the matching `callsArchetype` perk
-- can hook. Anything listed here is dropped from every other rod's catch roll,
-- so a species can be gated behind crafting a specific rod.
Rods.LOCKED_ARCHETYPES = { shambler = true }

export type Rod = {
	id: string,
	name: string,
	description: string,
	rarity: string, -- Common | Uncommon | Rare | Epic | Legendary
	icon: string, -- inventory image asset id ("rbxassetid://..."); "" shows the blank placeholder
	stats: RodStats,
	model: RodModel,
	reel: ReelConfig,
	recipe: Recipe?,
	perk: Perk?,
}

Rods.items = {} :: { [string]: Rod }

Rods.items.twig_rod = {
	id = "twig_rod",
	name = "Twig Rod",
	description = "Whittled from driftwood. Not much to it, but it casts.",
	rarity = "Common",
	icon = "rbxassetid://109180636672407", -- assets/icons/twig_rod.png
	model = {
		model = "RodPack",
		variant = "Twig",
		grip = 0.95,
		length = 7.0,
		-- Driftwood, dark cord, twine lashings, the classic red/white bobber.
		colors = {
			twig = Color3.fromRGB(139, 104, 68),
			grip = Color3.fromRGB(92, 81, 57),
			trim = Color3.fromRGB(70, 58, 44),
			line = Color3.fromRGB(224, 224, 214),
			bobberTop = Color3.fromRGB(217, 46, 41),
			bobberBottom = Color3.fromRGB(245, 245, 240),
		},
	},
	stats = {
		luck = 1.0,
		power = 1.0,
		control = 1.0,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
}

-- ============================================================ Starter Cove (L2-7)
-- Five craftable rods, one per gate step of the first island's band. Each is
-- its own variant in the RodPack (rod_gen.py), sharing the twig's grip/length
-- frame; the base `reel` stays the twig's and the stats differentiate
-- (FishingService.reelConfigFor scales barSpeed by power and widths by control).

Rods.items.bamboo_rod = {
	id = "bamboo_rod",
	name = "Bamboo Rod",
	description = "Springy and light. The forgiving bend makes a clean reel easy.",
	rarity = "Uncommon",
	icon = "rbxassetid://84238838974218", -- assets/icons/bamboo_rod.png
	model = {
		model = "RodPack",
		variant = "Bamboo",
		grip = 0.95,
		length = 7.0,
		-- Green cane, brass ferrules and guides, a slim orange-tipped quill float.
		colors = {
			twig = Color3.fromRGB(153, 173, 92),
			grip = Color3.fromRGB(87, 115, 61),
			trim = Color3.fromRGB(196, 154, 72),
			line = Color3.fromRGB(230, 230, 220),
			bobberTop = Color3.fromRGB(255, 170, 40),
			bobberBottom = Color3.fromRGB(238, 226, 196),
		},
	},
	stats = {
		luck = 1.0,
		power = 1.0,
		control = 1.25,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	recipe = {
		requiresLevel = 2,
		coins = 50,
		materials = { driftwood = 8, kelp_fiber = 5 },
	},
	perk = {
		id = "first_bend",
		name = "First Bend",
		description = "The springy blank absorbs one slip - your first miss each cast costs you nothing.",
		freeMisses = 1,
	},
}

Rods.items.anglers_rod = {
	id = "anglers_rod",
	name = "Angler's Rod",
	description = "Balanced and lucky. Draws out the rarer things in the water.",
	rarity = "Uncommon",
	icon = "rbxassetid://105908475522063", -- assets/icons/anglers_rod.png
	model = {
		model = "RodPack",
		variant = "Angler",
		grip = 0.95,
		length = 7.0,
		-- Varnished blank, cork handle, steel reel + guides, pale line, a
		-- bright orange pear float.
		colors = {
			twig = Color3.fromRGB(140, 84, 44),
			grip = Color3.fromRGB(204, 173, 120),
			trim = Color3.fromRGB(200, 204, 214),
			line = Color3.fromRGB(200, 224, 236),
			bobberTop = Color3.fromRGB(255, 128, 30),
			bobberBottom = Color3.fromRGB(250, 247, 240),
		},
	},
	stats = {
		luck = 1.4,
		power = 1.0,
		control = 1.05,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	recipe = {
		requiresLevel = 3,
		coins = 150,
		materials = { driftwood = 12, kelp_fiber = 10, fish_scale = 6 },
	},
	perk = {
		id = "chum_line",
		name = "Chum Line",
		description = "The water remembers. Every cast you see through raises your luck; walking away from one resets it.",
		streakLuck = 0.1,
		streakMax = 0.5,
	},
}

Rods.items.reefmaw_rod = {
	id = "reefmaw_rod",
	name = "Reefmaw Rod",
	description = "Barnacle-crusted salvage lashed into a rod. Heavy and forgiving - it bends where a lesser rod would snap.",
	rarity = "Rare",
	icon = "rbxassetid://110819740328819", -- assets/icons/reefmaw_rod.png
	model = {
		model = "RodPack",
		variant = "Reefmaw",
		grip = 0.95,
		length = 7.0,
		-- Weathered chitin shaft, dark cord, pale shell hardware, a coral float.
		colors = {
			twig = Color3.fromRGB(107, 117, 102),
			grip = Color3.fromRGB(69, 64, 54),
			trim = Color3.fromRGB(204, 199, 168),
			line = Color3.fromRGB(217, 224, 219),
			bobberTop = Color3.fromRGB(245, 140, 82),
			bobberBottom = Color3.fromRGB(237, 230, 209),
		},
	},
	stats = {
		luck = 1.1,
		power = 1.15,
		control = 1.3,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	recipe = {
		requiresLevel = 4,
		coins = 300,
		materials = { driftwood = 10, barnacle_chitin = 8, fish_scale = 6 },
	},
	perk = {
		id = "never_snaps",
		name = "Never Snaps",
		description = "It bends where a lesser rod would break - missed pulls never shrink your target.",
		noShrink = true,
	},
}

Rods.items.bonecaster_rod = {
	id = "bonecaster_rod",
	name = "Bonecaster Rod",
	description = "Cursed bone bound with brine-green light. It calls the drowned deep to give up its best.",
	rarity = "Epic",
	icon = "rbxassetid://137344620103835", -- assets/icons/bonecaster_rod.png
	model = {
		model = "RodPack",
		variant = "Bonecaster",
		grip = 0.95,
		length = 7.0,
		-- Pale bone shaft, dark brine grip, glowing green collars + wisp float.
		colors = {
			twig = Color3.fromRGB(204, 199, 173),
			grip = Color3.fromRGB(51, 59, 54),
			trim = Color3.fromRGB(115, 242, 140),
			line = Color3.fromRGB(77, 102, 87),
			bobberTop = Color3.fromRGB(140, 255, 153),
			bobberBottom = Color3.fromRGB(87, 89, 74),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = {
		luck = 1.6,
		power = 1.35,
		control = 1.0,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	-- Deliberately costs NO cursed_bone: shamblers (the only cursed_bone
	-- droppers) are locked behind this rod's callsArchetype, so this recipe
	-- is the key to that whole chain - pricing it in cursed_bone was a
	-- catch-22 (found in the 2026-08-25 thinning pass).
	recipe = {
		requiresLevel = 5,
		coins = 600,
		materials = { barnacle_chitin = 8, pearl = 4, fish_scale = 10 },
	},
	perk = {
		id = "drowned_tide",
		name = "Drowned Tide",
		description = "Only this bone calls the drowned up from the dark - and they drag nothing worse than Rare with them.",
		minRarity = "Rare",
		callsArchetype = "shambler",
	},
}

Rods.items.brineheart_rod = {
	id = "brineheart_rod",
	name = "Brineheart Rod",
	description = "Strung in the presence of Brinejaw's still-beating heart. The sea answers it, and it does not fray.",
	rarity = "Legendary",
	icon = "rbxassetid://80848359543719", -- assets/icons/brineheart_rod.png
	model = {
		model = "RodPack",
		variant = "Brineheart",
		grip = 0.95,
		length = 7.0,
		-- Deep red heartwood, bone hardware, a slow-pulsing red float.
		colors = {
			twig = Color3.fromRGB(104, 58, 62),
			grip = Color3.fromRGB(52, 34, 38),
			trim = Color3.fromRGB(226, 214, 190),
			line = Color3.fromRGB(240, 208, 208),
			bobberTop = Color3.fromRGB(255, 96, 104),
			bobberBottom = Color3.fromRGB(240, 232, 220),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = {
		luck = 1.9,
		power = 1.4,
		control = 1.35,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	-- The island's capstone: gated on the heart itself (owned, never spent),
	-- not on a heart material - beat Brinejaw and it's yours to build.
	recipe = {
		requiresLevel = 7,
		coins = 1500,
		materials = { volt_gland = 6, cursed_bone = 8, nacre = 5 },
		requiresHearts = { "brinejaw" },
	},
	perk = {
		id = "the_sea_answers",
		name = "The Sea Answers",
		description = "Nothing under Epic will take it, it reaches the far water, and the line simply never gives - missed pulls cost nothing.",
		minRarity = "Epic",
		castRange = 1.8,
		noShrink = true,
	},
}

-- ============================================================ Ashfall Caldera (L22-28)
-- The volcano's five, built from its material chain (ember / sulfur /
-- obsidian shard / magma core), gated for its FINAL slot-4 band (revamp
-- Session 4 re-gate; the interim island-2 gates are gone). Same twig frame;
-- each is its own RodPack variant in rod_gen.py.

Rods.items.cinderline_rod = {
	id = "cinderline_rod",
	name = "Cinderline Rod",
	description = "A driftwood shaft laced with cooling cinders. The line catches quick, and forgives the first slip.",
	rarity = "Uncommon",
	icon = "rbxassetid://113090539452817", -- assets/icons/cinderline_rod.png
	model = {
		model = "RodPack",
		variant = "Cinderline",
		grip = 0.95,
		length = 7.0,
		-- Driftwood scorched dark, ember-bright trim, a soot-pale line, an
		-- ember-orange float.
		colors = {
			twig = Color3.fromRGB(94, 72, 54),
			grip = Color3.fromRGB(61, 49, 39),
			trim = Color3.fromRGB(240, 132, 52),
			line = Color3.fromRGB(196, 181, 163),
			bobberTop = Color3.fromRGB(240, 132, 52),
			bobberBottom = Color3.fromRGB(60, 54, 46),
		},
	},
	stats = {
		luck = 1.05,
		power = 1.30,
		control = 1.05,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	recipe = {
		requiresLevel = 22,
		coins = 600,
		materials = { ember = 10, sulfur = 6, driftwood = 8 },
	},
	perk = {
		id = "cinder_catch",
		name = "Cinder Catch",
		description = "A spark catches before the line ever slips - your first miss each cast costs you nothing.",
		freeMisses = 1,
	},
}

Rods.items.obsidian_rod = {
	id = "obsidian_rod",
	name = "Obsidian Rod",
	description = "A blade of volcanic glass lashed to a shaft. Reaches the far pools, and won't waste the trip on anything common.",
	rarity = "Rare",
	icon = "rbxassetid://137969218362604", -- assets/icons/obsidian_rod.png
	model = {
		model = "RodPack",
		variant = "Obsidian",
		grip = 0.95,
		length = 7.0,
		-- Glassy black-obsidian shaft, glowing ember hardware, an
		-- ember-lit float.
		colors = {
			twig = Color3.fromRGB(48, 44, 60),
			grip = Color3.fromRGB(34, 31, 42),
			trim = Color3.fromRGB(240, 132, 52),
			line = Color3.fromRGB(90, 84, 100),
			bobberTop = Color3.fromRGB(240, 132, 52),
			bobberBottom = Color3.fromRGB(40, 37, 50),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = {
		luck = 1.20,
		power = 1.25,
		control = 1.15,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	recipe = {
		requiresLevel = 23,
		coins = 1300,
		materials = { obsidian_shard = 10, fish_scale = 8 },
	},
	perk = {
		id = "obsidian_edge",
		name = "Obsidian Edge",
		description = "Ground to a glassy edge that reaches the far pools and won't settle for anything less than Uncommon.",
		minRarity = "Uncommon",
		castRange = 1.5,
	},
}

Rods.items.cinderglass_rod = {
	id = "cinderglass_rod",
	name = "Cinderglass Rod",
	description = "Obsidian fused with hot cinder. It glows a little brighter the longer your streak holds.",
	rarity = "Rare",
	icon = "rbxassetid://136828664965550", -- assets/icons/cinderglass_rod.png
	model = {
		model = "RodPack",
		variant = "Cinderglass",
		grip = 0.95,
		length = 7.0,
		-- Obsidian fused with hot cinder, glowing magma-orange hardware
		-- and float.
		colors = {
			twig = Color3.fromRGB(48, 44, 60),
			grip = Color3.fromRGB(34, 31, 42),
			trim = Color3.fromRGB(244, 96, 40),
			line = Color3.fromRGB(100, 90, 100),
			bobberTop = Color3.fromRGB(244, 96, 40),
			bobberBottom = Color3.fromRGB(48, 44, 60),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = {
		luck = 1.25,
		power = 1.30,
		control = 1.10,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	recipe = {
		requiresLevel = 25,
		coins = 2400,
		materials = { obsidian_shard = 10, ember = 10, fish_scale = 4 },
	},
	perk = {
		id = "glass_streak",
		name = "Glass Streak",
		description = "Each landed cast anneals the glass a little brighter - your luck builds while the streak holds, and cools the moment you walk away.",
		streakLuck = 0.15,
		streakMax = 0.75,
	},
}

Rods.items.magma_core_rod = {
	id = "magma_core_rod",
	name = "Magma Core Rod",
	description = "A shard of the volcano's own heart, still warm. Casts far past the shallows, and won't hook anything under Rare.",
	rarity = "Epic",
	icon = "rbxassetid://73566616589133", -- assets/icons/magma_core_rod.png
	model = {
		model = "RodPack",
		variant = "MagmaCore",
		grip = 0.95,
		length = 7.0,
		-- A living coal bound into the blank, glowing magma-orange
		-- hardware and float.
		colors = {
			twig = Color3.fromRGB(60, 40, 34),
			grip = Color3.fromRGB(38, 26, 22),
			trim = Color3.fromRGB(244, 96, 40),
			line = Color3.fromRGB(150, 90, 80),
			bobberTop = Color3.fromRGB(244, 96, 40),
			bobberBottom = Color3.fromRGB(48, 32, 28),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = {
		luck = 1.45,
		power = 1.40,
		control = 1.20,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	recipe = {
		requiresLevel = 26,
		coins = 4500,
		materials = { magma_core = 6, sulfur = 10, fish_scale = 8 },
	},
	perk = {
		id = "molten_reach",
		name = "Molten Reach",
		description = "A living coal at its heart casts past the shallows and won't hook anything under Rare.",
		minRarity = "Rare",
		castRange = 1.4,
	},
}

Rods.items.phoenix_ash_rod = {
	id = "phoenix_ash_rod",
	name = "Phoenix Ash Rod",
	description = "Bound in the heat of the Caldera Wyrm's heart, dusted with ash of something that rose from its own fire. The line reaches water nothing else touches.",
	rarity = "Legendary",
	icon = "rbxassetid://127089528668845", -- assets/icons/phoenix_ash_rod.png
	model = {
		model = "RodPack",
		variant = "PhoenixAsh",
		grip = 0.95,
		length = 7.0,
		-- Ash the colour of a dying ember, glowing phoenix-bright
		-- hardware and float.
		colors = {
			twig = Color3.fromRGB(255, 168, 96),
			grip = Color3.fromRGB(120, 70, 50),
			trim = Color3.fromRGB(255, 168, 96),
			line = Color3.fromRGB(255, 220, 190),
			bobberTop = Color3.fromRGB(255, 168, 96),
			bobberBottom = Color3.fromRGB(244, 96, 40),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = {
		luck = 2.20,
		power = 1.60,
		control = 1.45,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	-- The volcano's capstone: gated on Pyrelisk's heart (owned, never spent).
	recipe = {
		requiresLevel = 28,
		coins = 9500,
		materials = { magma_core = 10, obsidian_shard = 12, ember = 15 },
		requiresHearts = { "pyrelisk" },
	},
	perk = {
		id = "rebirth_cast",
		name = "Rebirth Cast",
		description = "Ash of something that refused to stay dead - it reaches water no other line touches, never gives on a missed pull, and won't hook anything less than Epic.",
		minRarity = "Epic",
		castRange = 2.0,
		noShrink = true,
	},
}

-- ============================================================ Blackmire Fen (L8-14)
-- The swamp's five (revamp Session 2, docs/revamp-plan.md Island 2): U / R /
-- R / E / Legendary up the fen's band, costed in the fen's own material
-- chain. RodPack variants named for the art lane; the plain-cylinder
-- stand-in shows until they're generated + imported.

Rods.items.reedlash_rod = {
	id = "reedlash_rod",
	name = "Reedlash",
	description = "A whippy fen reed cured in bog water. It bends where stiffer rods snap.",
	rarity = "Uncommon",
	icon = "rbxassetid://124057711650911", -- assets/icons/reedlash_rod.png
	model = {
		model = "RodPack",
		variant = "Reedlash",
		grip = 0.95,
		length = 7.0,
		-- Cured reed, rust bindings, a cork-and-rust float.
		colors = {
			twig = Color3.fromRGB(148, 142, 90),
			grip = Color3.fromRGB(96, 88, 58),
			trim = Color3.fromRGB(164, 98, 62),
			line = Color3.fromRGB(214, 210, 190),
			bobberTop = Color3.fromRGB(164, 98, 62),
			bobberBottom = Color3.fromRGB(226, 216, 186),
		},
	},
	stats = {
		luck = 1.3,
		power = 1.1,
		control = 1.2,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	recipe = {
		requiresLevel = 8,
		coins = 300,
		materials = { bog_iron = 6, kelp_fiber = 8 },
	},
	perk = {
		id = "reed_bend",
		name = "Reed Bend",
		description = "The reed soaks up one slip - your first miss each cast costs you nothing.",
		freeMisses = 1,
	},
}

Rods.items.gatorback_rod = {
	id = "gatorback_rod",
	name = "Gatorback",
	description = "A blank armoured in gator scute. Nothing about it ever gives.",
	rarity = "Rare",
	icon = "rbxassetid://125120623233749", -- assets/icons/gatorback_rod.png
	model = {
		model = "RodPack",
		variant = "Gatorback",
		grip = 0.95,
		length = 7.0,
		-- Scute-green plates over dark iron, a bone-white float.
		colors = {
			twig = Color3.fromRGB(94, 116, 72),
			grip = Color3.fromRGB(58, 70, 48),
			trim = Color3.fromRGB(217, 208, 179),
			line = Color3.fromRGB(206, 210, 196),
			bobberTop = Color3.fromRGB(94, 116, 72),
			bobberBottom = Color3.fromRGB(226, 222, 200),
		},
	},
	stats = {
		luck = 1.45,
		power = 1.25,
		control = 1.3,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	recipe = {
		requiresLevel = 9,
		coins = 550,
		materials = { gator_scute = 8, bog_iron = 6 },
	},
	perk = {
		id = "armoured_line",
		name = "Armoured Line",
		description = "Scute-plated from butt to tip - the reel's zones never shrink, however many pulls you miss.",
		noShrink = true,
	},
}

Rods.items.wisplight_rod = {
	id = "wisplight_rod",
	name = "Wisplight",
	description = "A cold flame in a cage at the tip. The longer you follow it, the stranger what follows back.",
	rarity = "Rare",
	icon = "rbxassetid://81694768870172", -- assets/icons/wisplight_rod.png
	model = {
		model = "RodPack",
		variant = "Wisplight",
		grip = 0.95,
		length = 7.0,
		-- Bog-dark wood under a glowing wisp-green lantern and float.
		colors = {
			twig = Color3.fromRGB(74, 68, 54),
			grip = Color3.fromRGB(52, 48, 40),
			trim = Color3.fromRGB(150, 235, 200),
			line = Color3.fromRGB(198, 226, 212),
			bobberTop = Color3.fromRGB(150, 235, 200),
			bobberBottom = Color3.fromRGB(96, 150, 128),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = {
		luck = 1.6,
		power = 1.2,
		control = 1.25,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	recipe = {
		requiresLevel = 11,
		coins = 900,
		materials = { wisp_light = 5, bog_iron = 8, pearl = 2 },
	},
	perk = {
		id = "follow_the_light",
		name = "Follow the Light",
		description = "Every cast seen through feeds the flame - your luck grows with the streak, until you walk away from one.",
		streakLuck = 0.12,
		streakMax = 0.6,
	},
}

Rods.items.fenpiercer_rod = {
	id = "fenpiercer_rod",
	name = "Fenpiercer",
	description = "A lance of bog iron that casts clear across the murk and hooks nothing common.",
	rarity = "Epic",
	icon = "rbxassetid://110837057936062", -- assets/icons/fenpiercer_rod.png
	model = {
		model = "RodPack",
		variant = "Fenpiercer",
		grip = 0.95,
		length = 7.0,
		-- Rust-dark iron, venom-green fittings.
		colors = {
			twig = Color3.fromRGB(110, 74, 52),
			grip = Color3.fromRGB(64, 50, 42),
			trim = Color3.fromRGB(122, 103, 62),
			line = Color3.fromRGB(214, 222, 186),
			bobberTop = Color3.fromRGB(178, 210, 90),
			bobberBottom = Color3.fromRGB(120, 140, 70),
		},
		neon = { "Rod_BobberTop" },
	},
	stats = {
		luck = 1.75,
		power = 1.35,
		control = 1.3,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	recipe = {
		requiresLevel = 12,
		coins = 1400,
		materials = { fen_venom = 3, gator_scute = 8, wisp_light = 4 },
	},
	perk = {
		id = "deep_murk",
		name = "Deep Murk",
		description = "Casts half again as far into water others can't reach, and won't hook anything under Uncommon.",
		minRarity = "Uncommon",
		castRange = 1.5,
	},
}

Rods.items.mireheart_rod = {
	id = "mireheart_rod",
	name = "Mireheart Rod",
	description = "Cut from Old Gnashroot's root-bark in the presence of its still-beating heart. The whole fen answers it.",
	rarity = "Legendary",
	icon = "rbxassetid://98774088490960", -- assets/icons/mireheart_rod.png
	model = {
		model = "RodPack",
		variant = "Mireheart",
		grip = 0.95,
		length = 7.0,
		-- Moss-black root wood, the heart's wisp-glow in every fitting.
		colors = {
			twig = Color3.fromRGB(58, 66, 46),
			grip = Color3.fromRGB(44, 48, 36),
			trim = Color3.fromRGB(250, 191, 77),
			line = Color3.fromRGB(226, 218, 196),
			bobberTop = Color3.fromRGB(250, 191, 77),
			bobberBottom = Color3.fromRGB(58, 66, 46),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = {
		luck = 2.0,
		power = 1.45,
		control = 1.4,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	-- The fen's capstone: gated on the Tyrant's heart (owned, never spent).
	recipe = {
		requiresLevel = 14,
		coins = 3000,
		materials = { fen_venom = 5, wisp_light = 8, gator_scute = 10, bog_iron = 12 },
		requiresHearts = { "old_gnashroot" },
	},
	perk = {
		id = "the_fen_answers",
		name = "The Fen Answers",
		description = "Reaches further than anything the fen has seen, forgives two misses before the zones shrink, and won't hook anything under Rare.",
		minRarity = "Rare",
		castRange = 1.6,
		freeMisses = 2,
	},
}

-- ============================================================ Frostmaw Reach

Rods.items.auger_rod = {
	id = "auger_rod",
	name = "Auger Rod",
	description = "A stout drill-handled rod for working the ice holes. Forgiving when the cold stiffens your fingers.",
	rarity = "Uncommon",
	icon = "rbxassetid://118943003602313", -- assets/icons/auger_rod.png
	model = {
		model = "RodPack",
		variant = "Auger",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(150, 170, 186),
			grip = Color3.fromRGB(90, 104, 120),
			trim = Color3.fromRGB(210, 228, 240),
			line = Color3.fromRGB(220, 232, 240),
			bobberTop = Color3.fromRGB(120, 190, 255),
			bobberBottom = Color3.fromRGB(236, 244, 250),
		},
	},
	stats = { luck = 1.35, power = 1.15, control = 1.35 },
	reel = { clicksRequired = 3, barSpeed = 0.72, redWidth = 0.065, greenWidth = 0.2 },
	recipe = {
		requiresLevel = 15,
		coins = 500,
		materials = { glacier_shard = 8, driftwood = 10 },
	},
	perk = {
		id = "steady_hands",
		name = "Steady Hands",
		description = "The drill grip holds the line true - your first two misses never shrink the zones.",
		freeMisses = 2,
	},
}

Rods.items.rimebound_rod = {
	id = "rimebound_rod",
	name = "Rimebound Rod",
	description = "Frozen solid and all the stronger for it. The rime locks the zones where they stand - they never shrink at all.",
	rarity = "Rare",
	icon = "rbxassetid://112289781119428", -- assets/icons/rimebound_rod.png
	model = {
		model = "RodPack",
		variant = "Rimebound",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(178, 208, 226),
			grip = Color3.fromRGB(120, 140, 160),
			trim = Color3.fromRGB(240, 250, 255),
			line = Color3.fromRGB(210, 230, 244),
			bobberTop = Color3.fromRGB(240, 250, 255),
			bobberBottom = Color3.fromRGB(120, 160, 200),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = { luck = 1.5, power = 1.3, control = 1.35 },
	reel = { clicksRequired = 3, barSpeed = 0.68, redWidth = 0.06, greenWidth = 0.19 },
	recipe = {
		requiresLevel = 16,
		coins = 900,
		materials = { glacier_shard = 10, rime_pelt = 8, fish_scale = 6 },
	},
	perk = {
		id = "locked_in_ice",
		name = "Locked in Ice",
		description = "The rime holds the zones where they stand - misses never shrink them.",
		noShrink = true,
	},
}

Rods.items.silverscale_rod = {
	id = "silverscale_rod",
	name = "Silverscale Rod",
	description = "Wrapped in herring silver that flashes under the ice. Every cast seen through draws the next catch in luckier.",
	rarity = "Rare",
	icon = "rbxassetid://121595541902304", -- assets/icons/silverscale_rod.png
	model = {
		model = "RodPack",
		variant = "Silverscale",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(200, 212, 224),
			grip = Color3.fromRGB(140, 150, 164),
			trim = Color3.fromRGB(230, 240, 250),
			line = Color3.fromRGB(224, 234, 244),
			bobberTop = Color3.fromRGB(196, 220, 244),
			bobberBottom = Color3.fromRGB(255, 255, 255),
		},
	},
	stats = { luck = 1.65, power = 1.3, control = 1.3 },
	reel = { clicksRequired = 3, barSpeed = 0.66, redWidth = 0.06, greenWidth = 0.18 },
	recipe = {
		requiresLevel = 18,
		coins = 1400,
		materials = { rime_pelt = 12, everice = 5, pearl = 2 },
	},
	perk = {
		id = "silver_run",
		name = "Silver Run",
		description = "Each cast seen through to the catch flashes the silver brighter - luck grows with the streak.",
		streakLuck = 0.14,
		streakMax = 0.7,
	},
}

Rods.items.aurora_rod = {
	id = "aurora_rod",
	name = "Aurora Rod",
	description = "Strung with a thread of the southern lights. Small fish don't interest it - nothing under Rare takes the hook.",
	rarity = "Epic",
	icon = "rbxassetid://86663686430177", -- assets/icons/aurora_rod.png
	model = {
		model = "RodPack",
		variant = "Aurora",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(96, 140, 190),
			grip = Color3.fromRGB(60, 80, 110),
			trim = Color3.fromRGB(150, 230, 200),
			line = Color3.fromRGB(190, 240, 220),
			bobberTop = Color3.fromRGB(230, 150, 230),
			bobberBottom = Color3.fromRGB(150, 230, 200),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = { luck = 1.85, power = 1.45, control = 1.35 },
	reel = { clicksRequired = 3, barSpeed = 0.62, redWidth = 0.055, greenWidth = 0.17 },
	recipe = {
		requiresLevel = 19,
		coins = 2200,
		materials = { everice = 8, aurora_essence = 4, glacier_shard = 10 },
	},
	perk = {
		id = "southern_lights",
		name = "Southern Lights",
		description = "The lights in the line call to the deep reach - nothing under Rare takes the hook.",
		minRarity = "Rare",
	},
}

Rods.items.frostheart_rod = {
	id = "frostheart_rod",
	name = "Frostheart Rod",
	description = "Forged around a sliver of Rimefang's heart, still beating cold. The line reaches far under the sheet and never gives an inch.",
	rarity = "Legendary",
	icon = "rbxassetid://104321687645854", -- assets/icons/frostheart_rod.png
	model = {
		model = "RodPack",
		variant = "Frostheart",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(140, 180, 210),
			grip = Color3.fromRGB(80, 100, 126),
			trim = Color3.fromRGB(80, 220, 255),
			line = Color3.fromRGB(200, 240, 255),
			bobberTop = Color3.fromRGB(80, 220, 255),
			bobberBottom = Color3.fromRGB(236, 246, 252),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = { luck = 2.10, power = 1.50, control = 1.45 },
	reel = { clicksRequired = 3, barSpeed = 0.6, redWidth = 0.05, greenWidth = 0.16 },
	recipe = {
		requiresLevel = 21,
		coins = 2600,
		materials = { everice = 10, aurora_essence = 6, glacier_shard = 12 },
		requiresHearts = { "rimefang" },
	},
	perk = {
		id = "glacier_heart",
		name = "Glacier's Heart",
		description = "A sliver of the serpent's heart casts far under the sheet, never gives on a miss, and hooks nothing under Rare.",
		minRarity = "Rare",
		noShrink = true,
		castRange = 1.5,
	},
}

-- ============================================================ Gloomtrench

Rods.items.lanternline_rod = {
	id = "lanternline_rod",
	name = "Lanternline Rod",
	description = "A lantern gland hangs at the tip, the only light you get down here. Kind to numb hands in the dark.",
	rarity = "Uncommon",
	icon = "rbxassetid://139505841370157", -- assets/icons/lanternline_rod.png
	model = {
		model = "RodPack",
		variant = "Lanternline",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(80, 74, 96),
			grip = Color3.fromRGB(56, 50, 68),
			trim = Color3.fromRGB(255, 226, 130),
			line = Color3.fromRGB(150, 140, 170),
			bobberTop = Color3.fromRGB(255, 226, 130),
			bobberBottom = Color3.fromRGB(70, 62, 86),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = { luck = 1.6, power = 1.35, control = 1.4 },
	reel = { clicksRequired = 3, barSpeed = 0.7, redWidth = 0.06, greenWidth = 0.19 },
	recipe = {
		requiresLevel = 29,
		coins = 3200,
		materials = { gloom_scale = 10, lantern_gland = 3, driftwood = 12 },
	},
	perk = {
		id = "little_light",
		name = "A Little Light",
		description = "The lantern steadies you in the dark - your first two misses never shrink the zones.",
		freeMisses = 2,
	},
}

Rods.items.trenchglass_rod = {
	id = "trenchglass_rod",
	name = "Trenchglass Rod",
	description = "Blown from sand that has never seen the sun. It casts far out over the black water and bores small fish.",
	rarity = "Rare",
	icon = "rbxassetid://76760544210530", -- assets/icons/trenchglass_rod.png
	model = {
		model = "RodPack",
		variant = "Trenchglass",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(70, 84, 110),
			grip = Color3.fromRGB(41, 48, 66),
			trim = Color3.fromRGB(140, 220, 255),
			line = Color3.fromRGB(120, 150, 190),
			bobberTop = Color3.fromRGB(140, 220, 255),
			bobberBottom = Color3.fromRGB(52, 60, 84),
		},
		neon = { "Rod_Trim" },
	},
	stats = { luck = 1.75, power = 1.4, control = 1.4 },
	reel = { clicksRequired = 3, barSpeed = 0.66, redWidth = 0.06, greenWidth = 0.18 },
	recipe = {
		requiresLevel = 30,
		coins = 4200,
		materials = { gloom_scale = 12, trench_chitin = 8, pearl = 3 },
	},
	perk = {
		id = "deep_glass",
		name = "Deep Glass",
		description = "Casts far out over the black water, and nothing under Uncommon bothers it.",
		minRarity = "Uncommon",
		castRange = 1.5,
	},
}

Rods.items.inkveil_rod = {
	id = "inkveil_rod",
	name = "Inkveil Rod",
	description = "Dyed through with vampire-squid ink. The longer you fish the dark unbroken, the more it gives back.",
	rarity = "Rare",
	icon = "rbxassetid://89673336758041", -- assets/icons/inkveil_rod.png
	model = {
		model = "RodPack",
		variant = "Inkveil",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(56, 48, 72),
			grip = Color3.fromRGB(40, 34, 52),
			trim = Color3.fromRGB(136, 96, 204),
			line = Color3.fromRGB(110, 90, 150),
			bobberTop = Color3.fromRGB(170, 120, 255),
			bobberBottom = Color3.fromRGB(44, 38, 58),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = { luck = 1.9, power = 1.45, control = 1.45 },
	reel = { clicksRequired = 3, barSpeed = 0.64, redWidth = 0.055, greenWidth = 0.17 },
	recipe = {
		requiresLevel = 32,
		coins = 6000,
		materials = { lantern_gland = 6, gloom_scale = 14, trench_chitin = 8 },
	},
	perk = {
		id = "ink_run",
		name = "Ink Run",
		description = "Every cast seen through deepens the veil - luck grows with the streak, further than any silver.",
		streakLuck = 0.16,
		streakMax = 0.8,
	},
}

Rods.items.voidline_rod = {
	id = "voidline_rod",
	name = "Voidline Rod",
	description = "The line is a thread of the trench's own dark. It holds its zones forever and hooks nothing common.",
	rarity = "Epic",
	icon = "rbxassetid://139587872823087", -- assets/icons/voidline_rod.png
	model = {
		model = "RodPack",
		variant = "Voidline",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(40, 36, 56),
			grip = Color3.fromRGB(30, 26, 42),
			trim = Color3.fromRGB(170, 120, 255),
			line = Color3.fromRGB(90, 70, 130),
			bobberTop = Color3.fromRGB(120, 80, 220),
			bobberBottom = Color3.fromRGB(36, 32, 50),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = { luck = 2.1, power = 1.5, control = 1.45 },
	reel = { clicksRequired = 3, barSpeed = 0.62, redWidth = 0.05, greenWidth = 0.165 },
	recipe = {
		requiresLevel = 33,
		coins = 8000,
		materials = { abyss_ichor = 4, trench_chitin = 10, lantern_gland = 5 },
	},
	perk = {
		id = "the_void_holds",
		name = "The Void Holds",
		description = "Zones never shrink, and nothing under Rare dares the dark of this line.",
		minRarity = "Rare",
		noShrink = true,
	},
}

Rods.items.gloomheart_rod = {
	id = "gloomheart_rod",
	name = "Gloomheart Rod",
	description = "Bound around the Trench Mother's heart, which still remembers being the only light below. It reaches water no lantern finds and takes only the deep's best.",
	rarity = "Legendary",
	icon = "rbxassetid://123084455518199", -- assets/icons/gloomheart_rod.png
	model = {
		model = "RodPack",
		variant = "Gloomheart",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(58, 50, 78),
			grip = Color3.fromRGB(40, 34, 54),
			trim = Color3.fromRGB(255, 226, 130),
			line = Color3.fromRGB(200, 180, 240),
			bobberTop = Color3.fromRGB(255, 226, 130),
			bobberBottom = Color3.fromRGB(44, 38, 58),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = { luck = 2.35, power = 1.60, control = 1.50 },
	reel = { clicksRequired = 3, barSpeed = 0.6, redWidth = 0.05, greenWidth = 0.16 },
	recipe = {
		requiresLevel = 35,
		coins = 10000,
		materials = { abyss_ichor = 6, lantern_gland = 8, gloom_scale = 16 },
		requiresHearts = { "noctyss" },
	},
	perk = {
		id = "the_only_light",
		name = "The Only Light",
		description = "Her heart calls the trench's best from water no lantern finds - long casts, and nothing under Epic.",
		minRarity = "Epic",
		castRange = 1.8,
	},
}

-- ============================================================ Wreckwater

Rods.items.ghostplank_rod = {
	id = "ghostplank_rod",
	name = "Ghostplank Rod",
	description = "Sawn from a hull that still remembers floating. Forgiving, the way old wood is.",
	rarity = "Uncommon",
	icon = "rbxassetid://82599798020150", -- assets/icons/ghostplank_rod.png
	model = {
		model = "RodPack",
		variant = "Ghostplank",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(122, 130, 115),
			grip = Color3.fromRGB(75, 79, 71),
			trim = Color3.fromRGB(153, 161, 163),
			line = Color3.fromRGB(180, 196, 186),
			bobberTop = Color3.fromRGB(160, 255, 210),
			bobberBottom = Color3.fromRGB(90, 100, 93),
		},
	},
	stats = { luck = 1.9, power = 1.5, control = 1.5 },
	reel = { clicksRequired = 3, barSpeed = 0.68, redWidth = 0.06, greenWidth = 0.19 },
	recipe = {
		requiresLevel = 36,
		coins = 6500,
		materials = { ghost_plank = 10, kelp_fiber = 14 },
	},
	perk = {
		id = "old_wood",
		name = "Old Wood",
		description = "The plank has forgiven worse than you - your first two misses never shrink the zones.",
		freeMisses = 2,
	},
}

Rods.items.riggingline_rod = {
	id = "riggingline_rod",
	name = "Riggingline Rod",
	description = "Strung with rigging off the fleet, tarred and eternal. It does not shrink, and it hardly minds a miss.",
	rarity = "Rare",
	icon = "rbxassetid://74048107676509", -- assets/icons/riggingline_rod.png
	model = {
		model = "RodPack",
		variant = "Riggingline",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(115, 121, 107),
			grip = Color3.fromRGB(68, 73, 64),
			trim = Color3.fromRGB(196, 170, 115),
			line = Color3.fromRGB(160, 150, 126),
			bobberTop = Color3.fromRGB(220, 250, 236),
			bobberBottom = Color3.fromRGB(81, 90, 82),
		},
	},
	stats = { luck = 2.05, power = 1.55, control = 1.5 },
	reel = { clicksRequired = 3, barSpeed = 0.65, redWidth = 0.058, greenWidth = 0.18 },
	recipe = {
		requiresLevel = 37,
		coins = 8500,
		materials = { ghost_plank = 12, spectral_sailcloth = 5, fish_scale = 10 },
	},
	perk = {
		id = "tarred_line",
		name = "Tarred Line",
		description = "Rigging that outlasted its fleet - zones never shrink, and the first miss is free besides.",
		noShrink = true,
		freeMisses = 1,
	},
}

Rods.items.doubloon_rod = {
	id = "doubloon_rod",
	name = "Doubloon Rod",
	description = "Its guides are punched coins off the fleet's pay chest. Fortune loves a long run.",
	rarity = "Rare",
	icon = "rbxassetid://118958039098981", -- assets/icons/doubloon_rod.png
	model = {
		model = "RodPack",
		variant = "Doubloon",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(67, 57, 47),
			grip = Color3.fromRGB(45, 38, 32),
			trim = Color3.fromRGB(239, 196, 90),
			line = Color3.fromRGB(200, 180, 140),
			bobberTop = Color3.fromRGB(255, 218, 107),
			bobberBottom = Color3.fromRGB(79, 64, 43),
		},
		neon = { "Rod_BobberTop" },
	},
	stats = { luck = 2.2, power = 1.55, control = 1.55 },
	reel = { clicksRequired = 3, barSpeed = 0.63, redWidth = 0.055, greenWidth = 0.17 },
	recipe = {
		requiresLevel = 39,
		coins = 12000,
		materials = { tarnished_doubloon = 14, ghost_plank = 10, pearl = 4 },
	},
	perk = {
		id = "dead_mans_luck",
		name = "Dead Man's Luck",
		description = "Every cast seen through pays fortune forward - the strongest streak luck there is.",
		streakLuck = 0.18,
		streakMax = 0.9,
	},
}

Rods.items.sailcloth_rod = {
	id = "sailcloth_rod",
	name = "Sailcloth Rod",
	description = "A spar wrapped in spectral canvas that still holds a wind. It carries the cast far out among the wrecks and scorns small fish.",
	rarity = "Epic",
	icon = "rbxassetid://124469272368599", -- assets/icons/sailcloth_rod.png
	model = {
		model = "RodPack",
		variant = "Sailcloth",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(156, 170, 156),
			grip = Color3.fromRGB(97, 109, 101),
			trim = Color3.fromRGB(224, 252, 239),
			line = Color3.fromRGB(200, 220, 210),
			bobberTop = Color3.fromRGB(160, 255, 210),
			bobberBottom = Color3.fromRGB(115, 128, 119),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = { luck = 2.35, power = 1.6, control = 1.55 },
	reel = { clicksRequired = 3, barSpeed = 0.61, redWidth = 0.05, greenWidth = 0.165 },
	recipe = {
		requiresLevel = 40,
		coins = 16000,
		materials = { spectral_sailcloth = 8, wraith_essence = 3, tarnished_doubloon = 10 },
	},
	perk = {
		id = "ghost_wind",
		name = "Ghost Wind",
		description = "A wind nobody feels carries the cast far out among the wrecks - and nothing under Rare rides it back.",
		minRarity = "Rare",
		castRange = 1.7,
	},
}

Rods.items.wraithheart_rod = {
	id = "wraithheart_rod",
	name = "Wraithheart Rod",
	description = "The Admiral's heart is lashed to the reel seat, still giving orders. The whole drowned fleet answers it.",
	rarity = "Legendary",
	icon = "rbxassetid://137146386399045", -- assets/icons/wraithheart_rod.png
	model = {
		model = "RodPack",
		variant = "Wraithheart",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(54, 66, 64),
			grip = Color3.fromRGB(37, 47, 45),
			trim = Color3.fromRGB(140, 255, 205),
			line = Color3.fromRGB(190, 230, 210),
			bobberTop = Color3.fromRGB(160, 255, 210),
			bobberBottom = Color3.fromRGB(55, 71, 68),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = { luck = 2.50, power = 1.65, control = 1.55 },
	reel = { clicksRequired = 3, barSpeed = 0.6, redWidth = 0.05, greenWidth = 0.16 },
	recipe = {
		requiresLevel = 42,
		coins = 20000,
		materials = { wraith_essence = 6, spectral_sailcloth = 10, tarnished_doubloon = 16 },
		requiresHearts = { "admiral_wrack" },
	},
	perk = {
		id = "the_fleet_answers",
		name = "The Fleet Answers",
		description = "His heart still commands the graveyard - long casts, zones that never give, and nothing under Epic.",
		minRarity = "Epic",
		noShrink = true,
		castRange = 1.8,
	},
}

-- ============================================================ Rods

Rods.items.squallcaster_rod = {
	id = "squallcaster_rod",
	name = "Squallcaster Rod",
	description = "Cut from a mast that sailed into the Maelstrom and came back alone. It has no fear left.",
	rarity = "Uncommon",
	icon = "rbxassetid://84514111634354", -- assets/icons/squallcaster_rod.png
	model = {
		model = "RodPack",
		variant = "Squallcaster",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(110, 124, 140),
			grip = Color3.fromRGB(76, 86, 100),
			trim = Color3.fromRGB(190, 210, 230),
			line = Color3.fromRGB(200, 214, 228),
			bobberTop = Color3.fromRGB(140, 190, 230),
			bobberBottom = Color3.fromRGB(90, 102, 118),
		},
	},
	stats = { luck = 2.2, power = 1.6, control = 1.6 },
	reel = { clicksRequired = 3, barSpeed = 0.66, redWidth = 0.058, greenWidth = 0.18 },
	recipe = {
		requiresLevel = 43,
		coins = 12000,
		materials = { storm_glass = 10, driftwood = 16 },
	},
	perk = {
		id = "no_fear_left",
		name = "No Fear Left",
		description = "It has already seen the worst - your first two misses never shrink the zones.",
		freeMisses = 2,
	},
}

Rods.items.riptide_rod = {
	id = "riptide_rod",
	name = "Riptide Rod",
	description = "Strung with riptide sinew, it throws the line clean across the storm's shoulder and scorns anything small.",
	rarity = "Rare",
	icon = "rbxassetid://111134321267386", -- assets/icons/riptide_rod.png
	model = {
		model = "RodPack",
		variant = "Riptide",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(80, 110, 140),
			grip = Color3.fromRGB(56, 76, 98),
			trim = Color3.fromRGB(140, 200, 255),
			line = Color3.fromRGB(170, 200, 230),
			bobberTop = Color3.fromRGB(140, 200, 255),
			bobberBottom = Color3.fromRGB(60, 82, 106),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = { luck = 2.35, power = 1.65, control = 1.6 },
	reel = { clicksRequired = 3, barSpeed = 0.64, redWidth = 0.055, greenWidth = 0.17 },
	recipe = {
		requiresLevel = 44,
		coins = 16000,
		materials = { riptide_scale = 12, storm_glass = 10, pearl = 4 },
	},
	perk = {
		id = "against_the_current",
		name = "Against the Current",
		description = "Long casts across the storm - and nothing under Rare fights the riptide to reach them.",
		minRarity = "Rare",
		castRange = 1.6,
	},
}

Rods.items.thunderhead_rod = {
	id = "thunderhead_rod",
	name = "Thunderhead Rod",
	description = "A thunder pearl rides the tip, counting your patience. The storm pays the ones who stay out in it.",
	rarity = "Rare",
	icon = "rbxassetid://109518034618510", -- assets/icons/thunderhead_rod.png
	model = {
		model = "RodPack",
		variant = "Thunderhead",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(70, 80, 100),
			grip = Color3.fromRGB(156, 166, 186),
			trim = Color3.fromRGB(220, 230, 255),
			line = Color3.fromRGB(190, 200, 226),
			bobberTop = Color3.fromRGB(220, 230, 255),
			bobberBottom = Color3.fromRGB(56, 64, 84),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = { luck = 2.5, power = 1.65, control = 1.65 },
	reel = { clicksRequired = 3, barSpeed = 0.62, redWidth = 0.052, greenWidth = 0.165 },
	recipe = {
		requiresLevel = 46,
		coins = 22000,
		materials = { thunder_pearl = 8, storm_glass = 12, riptide_scale = 10 },
	},
	perk = {
		id = "count_the_thunder",
		name = "Count the Thunder",
		description = "Every cast seen through charges the pearl - the strongest streak luck a rod has carried.",
		streakLuck = 0.2,
		streakMax = 1.0,
	},
}

Rods.items.eyewall_rod = {
	id = "eyewall_rod",
	name = "Eyewall Rod",
	description = "Bent once around the storm's still centre and never straightened. Its zones are as calm as the eye, always.",
	rarity = "Epic",
	icon = "rbxassetid://115314321099842", -- assets/icons/eyewall_rod.png
	model = {
		model = "RodPack",
		variant = "Eyewall",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(90, 110, 150),
			grip = Color3.fromRGB(62, 76, 104),
			trim = Color3.fromRGB(90, 130, 255),
			line = Color3.fromRGB(170, 190, 240),
			bobberTop = Color3.fromRGB(90, 130, 255),
			bobberBottom = Color3.fromRGB(66, 80, 112),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = { luck = 2.6, power = 1.7, control = 1.65 },
	reel = { clicksRequired = 3, barSpeed = 0.61, redWidth = 0.05, greenWidth = 0.16 },
	recipe = {
		requiresLevel = 47,
		coins = 30000,
		materials = { maelstrom_core = 5, thunder_pearl = 8, riptide_scale = 12 },
	},
	perk = {
		id = "the_still_centre",
		name = "The Still Centre",
		description = "Zones never shrink, and nothing under Rare enters the eye.",
		minRarity = "Rare",
		noShrink = true,
	},
}

Rods.items.krakenheart_rod = {
	id = "krakenheart_rod",
	name = "Krakenheart Rod",
	description = "The Maw's own heart, caged in storm-glass at the reel seat. The sea has no better rod to give.",
	rarity = "Legendary",
	icon = "rbxassetid://111725817341513", -- assets/icons/krakenheart_rod.png
	model = {
		model = "RodPack",
		variant = "Krakenheart",
		grip = 0.95,
		length = 7.0,
		colors = {
			twig = Color3.fromRGB(60, 44, 84),
			grip = Color3.fromRGB(44, 34, 60),
			trim = Color3.fromRGB(150, 120, 255),
			line = Color3.fromRGB(200, 190, 240),
			bobberTop = Color3.fromRGB(150, 120, 255),
			bobberBottom = Color3.fromRGB(52, 40, 72),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = { luck = 2.70, power = 1.80, control = 1.70 },
	reel = { clicksRequired = 3, barSpeed = 0.6, redWidth = 0.05, greenWidth = 0.16 },
	recipe = {
		requiresLevel = 50,
		coins = 45000,
		materials = { maelstrom_core = 8, thunder_pearl = 10, storm_glass = 14 },
		requiresHearts = { "kraken" },
	},
	perk = {
		id = "the_sea_itself",
		name = "The Sea Itself",
		description = "The Maw's heart casts to the horizon, never yields a zone, and answers to nothing under Epic.",
		minRarity = "Epic",
		noShrink = true,
		castRange = 2.2,
	},
}

-- Every new player starts holding this one. See InventoryService.
Rods.STARTER_ROD_ID = "twig_rod"

-- Stable display order for the inventory / crafting menus (table iteration
-- order isn't guaranteed). Starter first, then by island and level gate.
Rods.order = {
	"twig_rod",
	"bamboo_rod",
	"anglers_rod",
	"reefmaw_rod",
	"bonecaster_rod",
	"brineheart_rod",
	"reedlash_rod",
	"gatorback_rod",
	"wisplight_rod",
	"fenpiercer_rod",
	"mireheart_rod",
	"auger_rod",
	"rimebound_rod",
	"silverscale_rod",
	"aurora_rod",
	"frostheart_rod",
	"cinderline_rod",
	"obsidian_rod",
	"cinderglass_rod",
	"magma_core_rod",
	"phoenix_ash_rod",
	"lanternline_rod",
	"trenchglass_rod",
	"inkveil_rod",
	"voidline_rod",
	"gloomheart_rod",
	"ghostplank_rod",
	"riggingline_rod",
	"doubloon_rod",
	"sailcloth_rod",
	"wraithheart_rod",
	"squallcaster_rod",
	"riptide_rod",
	"thunderhead_rod",
	"eyewall_rod",
	"krakenheart_rod",
}

return Rods
