--!nonstrict
-- Shops.luau
-- NPC shop stock, as data. A shop belongs to an NPC (Npcs.items.<id>.shop
-- names a row here); its stock is a list of priced slots the dialog's shop
-- pane renders as buy buttons. NpcService owns the whole transaction - the
-- client only ever echoes "buy slot N", and the server re-derives the slot,
-- checks coins, spends, grants. Coins finally have a real SINK.
--
-- Slot kinds:
--   { kind = "bait",     id, amount, price }  - BaitService.grant
--   { kind = "material", id, amount, price }  - MaterialService.grant
-- `stock` is the fixed shelf; `rotating = { slots = n, pool = { slot... } }`
-- adds n MORE shelves drawn from the pool per UTC day - deterministic
-- (seeded by day + shop id in NpcService), so the server re-derives the
-- same shelves to validate a buy and nothing is stored.

local Shops = {}

export type Slot = { kind: string, id: string, amount: number, price: number }
export type Shop = { id: string, stock: { Slot } }

Shops.items = {} :: { [string]: Shop }

-- Old Maren's general stall: starter bait and rack scraps. Priced a shade
-- over the crafting cost - the shop is convenience, crafting stays the
-- economical path.
Shops.items.marens_stall = {
	id = "marens_stall",
	stock = {
		{ kind = "bait", id = "chum", amount = 5, price = 60 },
		{ kind = "material", id = "driftwood", amount = 5, price = 45 },
		{ kind = "material", id = "kelp_fiber", amount = 5, price = 45 },
		{ kind = "material", id = "nacre", amount = 1, price = 120 },
		{ kind = "item", id = "chitin_helm", amount = 1, price = 480 },
		-- The Tideward cowl is Old Maren's quest gift (the_wider_water);
		-- the stall sells it to anyone who sailed past her advice.
		{ kind = "item", id = "tideward_helm", amount = 1, price = 900 },
	},
	rotating = {
		slots = 2,
		pool = {
			{ kind = "bait", id = "bloodbait", amount = 3, price = 140 },
			{ kind = "bait", id = "glowgrub", amount = 2, price = 220 },
			{ kind = "material", id = "pearl", amount = 1, price = 260 },
			{ kind = "material", id = "barnacle_chitin", amount = 2, price = 150 },
			{ kind = "material", id = "fish_scale", amount = 4, price = 90 },
		},
	},
}

-- Halvard's cache: cold-water conveniences.
Shops.items.halvards_cache = {
	id = "halvards_cache",
	stock = {
		{ kind = "item", id = "rimebound_legs", amount = 1, price = 1400 },
		{ kind = "material", id = "everice", amount = 2, price = 420 },
		{ kind = "material", id = "glacier_shard", amount = 1, price = 520 },
	},
	rotating = {
		slots = 1,
		pool = {
			{ kind = "bait", id = "glowgrub", amount = 3, price = 300 },
			{ kind = "material", id = "aurora_essence", amount = 1, price = 800 },
		},
	},
}

-- Brakk's forge counter: what the mountain coughs up.
Shops.items.brakks_forge = {
	id = "brakks_forge",
	stock = {
		{ kind = "item", id = "cindershell_chest", amount = 1, price = 3200 },
		{ kind = "material", id = "sulfur", amount = 3, price = 380 },
		{ kind = "material", id = "ember", amount = 2, price = 450 },
	},
	rotating = {
		slots = 1,
		pool = {
			{ kind = "material", id = "obsidian_shard", amount = 1, price = 700 },
			{ kind = "material", id = "magma_core", amount = 1, price = 1200 },
		},
	},
}

-- Quartermaster Hollow's locker: the drowned fleet's salvage, sold by the
-- book. The Corsair's Rest plate is bought, never forged - the fleet does
-- not teach outsiders to work its dead (the helm is quest-pinned instead:
-- ledger_of_teeth).
Shops.items.hollows_locker = {
	id = "hollows_locker",
	stock = {
		{ kind = "item", id = "corsairs_rest_chest", amount = 1, price = 5200 },
		{ kind = "item", id = "corsairs_rest_legs", amount = 1, price = 3800 },
		{ kind = "material", id = "ghost_plank", amount = 2, price = 600 },
		{ kind = "material", id = "spectral_sailcloth", amount = 1, price = 750 },
	},
	rotating = {
		slots = 1,
		pool = {
			{ kind = "material", id = "tarnished_doubloon", amount = 2, price = 520 },
			{ kind = "material", id = "wraith_essence", amount = 1, price = 950 },
		},
	},
}

-- The Ferryman's counter, six thousand studs from the nearest shore. He
-- stocks a little of every leg and charges for the distance: nothing here is
-- unavailable elsewhere, it is all unavailable ANYWHERE NEAR HERE, which is
-- the whole of his business. The markup is the character and it is meant to
-- be legible - specialty goods run ~30% over the island that produces them
-- (Halvard sells glowgrub at 100 a grub, Brakk sulfur at ~127), and plain
-- commodities run double, because running out of kelp fibre mid-voyage is
-- exactly the moment he is pricing. He is the only person out here and both
-- of you know it.
Shops.items.ferrymans_stock = {
	id = "ferrymans_stock",
	stock = {
		{ kind = "bait", id = "glowgrub", amount = 3, price = 390 },
		{ kind = "bait", id = "frostgrub", amount = 3, price = 420 },
		{ kind = "bait", id = "ember_roe", amount = 3, price = 450 },
		{ kind = "material", id = "driftwood", amount = 5, price = 90 },
		{ kind = "material", id = "kelp_fiber", amount = 5, price = 90 },
	},
	rotating = {
		slots = 2,
		pool = {
			{ kind = "material", id = "bog_iron", amount = 2, price = 340 },
			{ kind = "material", id = "glacier_shard", amount = 1, price = 680 },
			{ kind = "material", id = "sulfur", amount = 3, price = 495 },
			{ kind = "material", id = "ghost_plank", amount = 2, price = 780 },
			{ kind = "bait", id = "lanternbait", amount = 2, price = 520 },
		},
	},
}

return Shops
