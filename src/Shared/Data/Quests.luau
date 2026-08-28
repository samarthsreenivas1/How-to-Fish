--!nonstrict
-- Quests.luau
-- Every quest, as data. A quest belongs to an NPC (`giver` - it appears in
-- their dialog when offerable), carries a list of typed OBJECTIVES that must
-- ALL complete, and pays `rewards` at turn-in. QuestService owns all state
-- and progress; this file is pure rows.
--
-- Objective types (the matcher in QuestService):
--   { type = "catch", count = n, species = id?, rarity = name?, waters = key? }
--       - a resolved cast's creature. Filters are AND; absent = any.
--   { type = "kill", count = n, species = id?, rarity = name? }        (A4)
--   { type = "craft", itemId = id }                                    (A4)
--   { type = "deliver", materials = { [matId] = n } }                  (A4)
--       - checked AND SPENT at turn-in, not tracked live.
--   { type = "visit", island = id }                                    (A4)
-- RULE: an event ticks EVERY matching objective on every active quest - a
-- swamp Rare catch advances both a "5 swamp fish" and a "3 Rare fish" quest.
--
-- `prereq` (quest id) + `requiresLevel` gate when a quest is OFFERED;
-- `repeatable = "daily"` re-offers after a UTC day (A5). Rewards may carry
-- coins, xp, materials = {[matId]=n}, bait = {[baitId]=n}.

local Quests = {}

export type Objective = {
	type: string,
	count: number?,
	species: string?,
	rarity: string?,
	waters: string?,
	itemId: string?,
	materials: { [string]: number }?,
	island: string?,
}

export type Quest = {
	id: string,
	name: string,
	giver: string, -- Npcs.luau id
	blurb: string, -- the pitch, shown on the offer pane
	objectives: { Objective },
	prereq: string?,
	requiresLevel: number?,
	repeatable: (boolean | string)?,
	rewards: {
		coins: number?,
		xp: number?,
		materials: { [string]: number }?,
		bait: { [string]: number }?,
	},
}

Quests.items = {} :: { [string]: Quest }

-- Old Maren's opener: the tutorial-shaped first errand. Any five catches -
-- every catch fights back now, so this teaches the whole loop.
Quests.items.marens_wager = {
	id = "marens_wager",
	name = "Maren's Wager",
	giver = "old_maren",
	blurb = "Five catches, landed and put down. Prove the cove hasn't gotten the better of you, and I'll make it worth the bruises.",
	objectives = {
		{ type = "catch", count = 5 },
	},
	rewards = { coins = 150, xp = 120 },
}

return Quests
