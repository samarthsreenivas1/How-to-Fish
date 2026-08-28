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
-- Fixed stock for now; the daily rotation (deterministic UTC-day seed over
-- a weighted pool) is the C5 slice and changes this schema additively.

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
	},
}

return Shops
