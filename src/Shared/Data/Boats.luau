--!nonstrict
-- Boats.luau
-- The drivable boat's upgrade ladder (docs/revamp-plan.md, Session 3), as
-- rows rather than code. A player owns exactly ONE boat at a time - their
-- tier, held as the replicated `BoatTier` Player attribute (persisted by
-- DataService as profile.boatTier) - and each row here describes what the
-- boat IS at that tier: how it looks (BoatModel builds it from `model`), how
-- it drives (speed/turn), how much open sea it survives (`seaworthiness`,
-- BoatService's DoT gate), and what upgrading to it costs (`recipe`, spent
-- through the item-agnostic CraftingService like any rod or weapon).
--
-- Tier 1 is never crafted: BoatService grants it when Brinejaw falls (it
-- watches the Heart_brinejaw attribute, so a returning player who beat the
-- boss before boats existed is back-filled on their next login). Tiers 2-6
-- are the game's big between-island coin sink; each one is the plan's gate
-- for the NEXT crossing (WorldService.mayEnter checks the traveller's
-- BoatTier against the destination's position in Islands.order).

local Boats = {}

-- How the boat looks. `variant` picks a hull out of the shared "BoatPack"
-- mesh (assets/boat_gen.py, once imported); until the pack exists BoatModel
-- builds every tier procedurally from the same numbers, so the boat is
-- drivable the moment this file lands. All dimensions are in studs and are
-- the PHYSICS truth (the invisible hull collider is sized from them) - a
-- mesh variant must stay inside them.
--   length/beam - hull footprint (bow along -Z).
--   deckHeight  - deck top above the waterline; the collider reaches this high.
--   draft       - hull bottom below the waterline.
export type BoatModelSpec = {
	variant: string,
	length: number,
	beam: number,
	deckHeight: number,
	draft: number,
	colors: { [string]: Color3 },
	neon: { string }?,
}

export type BoatRow = {
	id: string,
	tier: number,
	name: string,
	blurb: string,
	rarity: string,
	speed: number, -- top speed, studs/s
	turnRate: number, -- degrees/s at full rudder
	hullHealth: number, -- what the open-sea DoT chews through before the boat sinks
	seaworthiness: number, -- studs from the nearest ENTERABLE island before the DoT starts
	model: BoatModelSpec,
	recipe: {
		requiresLevel: number,
		coins: number,
		materials: { [string]: number },
	}?,
}

-- Seaworthiness must clear half the 3000-stud island spacing (the farthest a
-- straight crossing ever puts you from the nearer of the two islands, once
-- the destination itself counts as enterable) with margin for a wobbly
-- course; it grows per tier purely so better hulls FEEL sturdier further out.
Boats.items = {
	cove_skiff = {
		id = "cove_skiff",
		tier = 1,
		name = "Cove Skiff",
		blurb = "Brinejaw's bounty - a humble hull, but it floats.",
		rarity = "Common",
		speed = 30,
		turnRate = 70,
		hullHealth = 100,
		seaworthiness = 1750,
		model = {
			variant = "CoveSkiff",
			length = 14,
			beam = 5,
			deckHeight = 1.2,
			draft = 0.9,
			colors = {
				hull = Color3.fromRGB(146, 106, 66),
				deck = Color3.fromRGB(178, 138, 90),
				trim = Color3.fromRGB(94, 66, 40),
				sail = Color3.fromRGB(232, 222, 196),
				glow = Color3.fromRGB(255, 214, 130),
			},
		},
		-- No recipe: granted on Brinejaw's fall, never crafted.
	},

	ironbog_hull = {
		id = "ironbog_hull",
		tier = 2,
		name = "Ironbog Hull",
		blurb = "Bog-iron plating shrugs off the fen's snags.",
		rarity = "Uncommon",
		speed = 34,
		turnRate = 74,
		hullHealth = 150,
		seaworthiness = 1900,
		model = {
			variant = "IronbogHull",
			length = 16,
			beam = 5.5,
			deckHeight = 1.4,
			draft = 1.0,
			colors = {
				hull = Color3.fromRGB(96, 84, 60),
				deck = Color3.fromRGB(140, 116, 78),
				trim = Color3.fromRGB(70, 74, 66),
				sail = Color3.fromRGB(196, 188, 158),
				glow = Color3.fromRGB(170, 226, 130),
			},
		},
		recipe = { requiresLevel = 8, coins = 1500, materials = { bog_iron = 20, gator_scute = 10 } },
	},

	icebreaker_prow = {
		id = "icebreaker_prow",
		tier = 3,
		name = "Icebreaker Prow",
		blurb = "A glacier-shard ram for seas that bite back.",
		rarity = "Rare",
		speed = 38,
		turnRate = 78,
		hullHealth = 200,
		seaworthiness = 2050,
		model = {
			variant = "IcebreakerProw",
			length = 18,
			beam = 6,
			deckHeight = 1.6,
			draft = 1.1,
			colors = {
				hull = Color3.fromRGB(120, 140, 152),
				deck = Color3.fromRGB(168, 182, 190),
				trim = Color3.fromRGB(84, 104, 118),
				sail = Color3.fromRGB(224, 236, 244),
				glow = Color3.fromRGB(150, 220, 255),
			},
		},
		recipe = { requiresLevel = 15, coins = 4000, materials = { glacier_shard = 20, everice = 8 } },
	},

	ashguard_plating = {
		id = "ashguard_plating",
		tier = 4,
		name = "Ashguard Plating",
		blurb = "Obsidian scales - the caldera's heat slides right off.",
		rarity = "Rare",
		speed = 42,
		turnRate = 82,
		hullHealth = 260,
		seaworthiness = 2200,
		model = {
			variant = "AshguardPlating",
			length = 20,
			beam = 6.5,
			deckHeight = 1.8,
			draft = 1.2,
			colors = {
				hull = Color3.fromRGB(58, 54, 56),
				deck = Color3.fromRGB(92, 84, 82),
				trim = Color3.fromRGB(36, 32, 34),
				sail = Color3.fromRGB(168, 148, 138),
				glow = Color3.fromRGB(255, 120, 40),
			},
			neon = { "Boat_Lantern" },
		},
		recipe = { requiresLevel = 22, coins = 9000, materials = { obsidian_shard = 25, magma_core = 6 } },
	},

	abyssal_lanterns = {
		id = "abyssal_lanterns",
		tier = 5,
		name = "Abyssal Lanterns",
		blurb = "Gland-lit lanterns hold the trench dark off the deck.",
		rarity = "Epic",
		speed = 46,
		turnRate = 86,
		hullHealth = 330,
		seaworthiness = 2350,
		model = {
			variant = "AbyssalLanterns",
			length = 22,
			beam = 7,
			deckHeight = 2.0,
			draft = 1.3,
			colors = {
				hull = Color3.fromRGB(44, 52, 74),
				deck = Color3.fromRGB(70, 80, 104),
				trim = Color3.fromRGB(30, 34, 50),
				sail = Color3.fromRGB(120, 134, 168),
				glow = Color3.fromRGB(120, 240, 220),
			},
			neon = { "Boat_Lantern" },
		},
		recipe = { requiresLevel = 29, coins = 18000, materials = { lantern_gland = 15, abyss_ichor = 6 } },
	},

	stormbreaker_keel = {
		id = "stormbreaker_keel",
		tier = 6,
		name = "Stormbreaker Keel",
		blurb = "Sailcloth of ghosts, keel of wraiths - fit to cross the Maelstrom.",
		rarity = "Legendary",
		speed = 52,
		turnRate = 90,
		hullHealth = 420,
		seaworthiness = 2600,
		model = {
			variant = "StormbreakerKeel",
			length = 24,
			beam = 8,
			deckHeight = 2.2,
			draft = 1.4,
			colors = {
				hull = Color3.fromRGB(52, 58, 66),
				deck = Color3.fromRGB(88, 96, 106),
				trim = Color3.fromRGB(196, 174, 110),
				sail = Color3.fromRGB(214, 226, 236),
				glow = Color3.fromRGB(170, 200, 255),
			},
			neon = { "Boat_Lantern", "Boat_Trim" },
		},
		recipe = { requiresLevel = 36, coins = 35000, materials = { spectral_sailcloth = 15, wraith_essence = 8 } },
	},
}

-- Crafting-menu display order (the upgrade ladder, bottom up).
Boats.order = {
	"cove_skiff",
	"ironbog_hull",
	"icebreaker_prow",
	"ashguard_plating",
	"abyssal_lanterns",
	"stormbreaker_keel",
}

-- tier -> row, for "what boat does BoatTier = n mean" lookups.
Boats.byTier = {}
for _, id in Boats.order do
	local row = Boats.items[id]
	Boats.byTier[row.tier] = row
end

-- The highest tier (the ladder's top; used for "already best boat" checks).
Boats.MAX_TIER = #Boats.order

return Boats
