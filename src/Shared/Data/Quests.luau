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

-- The follow-up: the cove's crabs have been at her drying racks.
Quests.items.teeth_of_the_cove = {
	id = "teeth_of_the_cove",
	name = "Teeth of the Cove",
	giver = "old_maren",
	blurb = "The snapjaws have chewed through two of my racks this week. Thin them out - and while you're wading, land me something with a bit of shine to it.",
	prereq = "marens_wager",
	objectives = {
		{ type = "kill", count = 4, species = "snapjaw_crab" },
		{ type = "catch", count = 2, rarity = "Rare" },
	},
	rewards = { coins = 320, xp = 260, materials = { driftwood = 4 } },
}

-- The chain's capstone: she points you at the wider world. Craft (the
-- bamboo rod is the first recipe anyone can reach), bring her kelp for her
-- racks, and set foot on the fen - every objective type is live from here.
Quests.items.the_wider_water = {
	id = "the_wider_water",
	name = "The Wider Water",
	giver = "old_maren",
	blurb = "You've outgrown my little cove, love. Lash yourself a proper rod, bring me kelp for the racks before you go - and when you stand in the Blackmire mud, think of old Maren.",
	prereq = "teeth_of_the_cove",
	requiresLevel = 5,
	objectives = {
		{ type = "craft", itemId = "bamboo_rod" },
		{ type = "deliver", materials = { kelp_fiber = 6 } },
		{ type = "visit", island = "swamp" },
	},
	rewards = { coins = 500, xp = 420 },
}

return Quests
