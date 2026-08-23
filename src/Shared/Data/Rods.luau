--!nonstrict
-- Rods.luau
-- Rod content, as rows rather than code. Every rod a player can hold -
-- starter gear, shop unlocks, crafted rods later - is one entry in
-- `Rods.items`, keyed by id. Adding a rod is a new entry here, never a new
-- code path.
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
-- `requiresLevel` gates it behind the player's level. Same shape will
-- describe weapon recipes later - crafting is item-agnostic.
export type Recipe = {
	requiresLevel: number,
	coins: number,
	materials: { [string]: number },
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
	icon = "rbxassetid://130356674679888", -- assets/icons/twig_rod.png
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

-- ============================================================ Craftable

-- Each is its own variant in the RodPack (rod_gen.py), sharing the twig's
-- grip/length frame. Each leans into one stat; the base `reel` stays the
-- twig's and the stats do the differentiating (FishingService.reelConfigFor
-- scales barSpeed by power and the zone widths by control). Recipes escalate
-- in level, mats and coins.

Rods.items.bamboo_rod = {
	id = "bamboo_rod",
	name = "Bamboo Rod",
	description = "Springy and light. The forgiving bend makes a clean reel easy.",
	rarity = "Uncommon",
	icon = "rbxassetid://96558490595842", -- assets/icons/bamboo_rod.png
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
	icon = "rbxassetid://83720381061744", -- assets/icons/anglers_rod.png
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
		requiresLevel = 5,
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

Rods.items.abyssal_rod = {
	id = "abyssal_rod",
	name = "Abyssal Rod",
	description = "Forged for the deep. Fast and unforgiving, but it lands legends.",
	rarity = "Rare",
	icon = "rbxassetid://127315429765321", -- assets/icons/abyssal_rod.png
	model = {
		model = "RodPack",
		variant = "Abyssal",
		grip = 0.95,
		length = 7.0,
		-- Black iron with glowing teal rings, a dark line, and an anglerfish
		-- lantern for a float: glowing orb over an iron cage.
		colors = {
			twig = Color3.fromRGB(40, 44, 60),
			grip = Color3.fromRGB(31, 33, 46),
			trim = Color3.fromRGB(64, 224, 208),
			line = Color3.fromRGB(60, 68, 88),
			bobberTop = Color3.fromRGB(90, 240, 220),
			bobberBottom = Color3.fromRGB(28, 30, 40),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = {
		luck = 1.15,
		power = 1.3,
		control = 1.1,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	recipe = {
		requiresLevel = 10,
		coins = 400,
		materials = { fish_scale = 15, pearl = 3 },
	},
	perk = {
		id = "abyssal_pull",
		name = "Abyssal Pull",
		description = "Built for water no other line reaches: it casts far past the shallows, and the deep never surrenders commons.",
		minRarity = "Uncommon",
		castRange = 1.6,
	},
}

-- ============================================================ Rare / Epic (creature mats)
-- Two rods built from the mats the hostile creatures drop (Creatures.luau
-- drops): barnacle chitin off the Snapjaw Crab, cursed bone off the drowned.
-- They share the twig frame (grip 0.95 / length 7.0) like the others; each is
-- its own RodPack variant in rod_gen.py.

Rods.items.reefmaw_rod = {
	id = "reefmaw_rod",
	name = "Reefmaw Rod",
	description = "Barnacle-crusted salvage lashed into a rod. Heavy and forgiving - it bends where a lesser rod would snap.",
	rarity = "Rare",
	icon = "rbxassetid://75693911870683", -- assets/icons/reefmaw_rod.png
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
		requiresLevel = 8,
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
	icon = "rbxassetid://118185763168636", -- assets/icons/bonecaster_rod.png
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
	recipe = {
		requiresLevel = 14,
		coins = 600,
		materials = { cursed_bone = 10, pearl = 4, barnacle_chitin = 5 },
	},
	perk = {
		id = "drowned_tide",
		name = "Drowned Tide",
		description = "Only this bone calls the drowned up from the dark - and they drag nothing worse than Rare with them.",
		minRarity = "Rare",
		callsArchetype = "shambler",
	},
}

-- ============================================================ Epic / Legendary (new creature mats)
-- Built from what the later hostiles drop: a Voltray's electric organ and a
-- Pearl Mimic's nacre, and - once Brinejaw is dead - its heart. Same RodPack
-- frame (grip 0.95 / length 7.0); each is its own variant in rod_gen.py.

Rods.items.voltline_rod = {
	id = "voltline_rod",
	name = "Voltline Rod",
	description = "A Voltray's organ wound into the blank. The line hums, and nothing small comes near it.",
	rarity = "Epic",
	icon = "",
	model = {
		model = "RodPack",
		variant = "Voltline",
		grip = 0.95,
		length = 7.0,
		-- Dark blank, pale nacre hardware, a crackling blue float.
		colors = {
			twig = Color3.fromRGB(58, 64, 82),
			grip = Color3.fromRGB(38, 42, 54),
			trim = Color3.fromRGB(206, 222, 236),
			line = Color3.fromRGB(178, 220, 246),
			bobberTop = Color3.fromRGB(126, 214, 255),
			bobberBottom = Color3.fromRGB(236, 246, 252),
		},
		neon = { "Rod_Trim", "Rod_BobberTop" },
	},
	stats = {
		luck = 1.5,
		power = 1.5, -- the fastest bar of any rod
		control = 1.15,
	},
	reel = {
		clicksRequired = 3,
		barSpeed = 0.6,
		redWidth = 0.05,
		greenWidth = 0.16,
	},
	recipe = {
		requiresLevel = 16,
		coins = 700,
		materials = { volt_gland = 8, nacre = 6, pearl = 3 },
	},
	perk = {
		id = "live_wire",
		name = "Live Wire",
		description = "The charge scares off the small fry and reaches water a shorter line can't - nothing under Rare, and a longer cast besides.",
		minRarity = "Rare",
		castRange = 1.3,
	},
}

Rods.items.brineheart_rod = {
	id = "brineheart_rod",
	name = "Brineheart Rod",
	description = "Strung on a thread of Brinejaw's heart. The sea answers it, and it does not fray.",
	rarity = "Legendary",
	icon = "",
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
	recipe = {
		requiresLevel = 20,
		coins = 1500,
		materials = { brineheart = 1, volt_gland = 6, cursed_bone = 8 },
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

-- Every new player starts holding this one. See InventoryService.
Rods.STARTER_ROD_ID = "twig_rod"

return Rods
